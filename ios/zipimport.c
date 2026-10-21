/*
 zipimport.c - unpacks the player's game zips (valve.zip, cstrike.zip, ...)
 Copyright (C) 2026 cs1.6-to-ios contributors

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
*/

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include "zlib_wrapper.h"
#include "zipimport.h"

#define ZI_CHUNK        ( 256 * 1024 )
#define ZI_MAX_PATH     4096
#define ZI_SIG_LOCAL    0x04034b50u
#define ZI_SIG_CENTRAL  0x02014b50u
#define ZI_SIG_EOCD     0x06054b50u
#define ZI_SIG_EOCD64   0x06064b50u
#define ZI_SIG_LOC64    0x07064b50u

typedef struct zi_entry_s
{
	uint64_t csize;
	uint64_t usize;
	uint64_t offset;
	uint32_t crc;
	uint32_t nameofs; // into the central directory buffer
	uint16_t namelen;
	uint16_t method;
	uint16_t flags;
} zi_entry_t;

typedef struct zi_state_s
{
	FILE                 *f;
	uint8_t              *inbuf;
	uint8_t              *outbuf;
	zipimport_progress_t progress;
	void                 *ctx;
	unsigned long long   done;
	unsigned long long   total;
	char                 *err;
	size_t               errsize;
} zi_state_t;

static uint32_t zi_crc_table[256];

static void ZI_InitCRC( void )
{
	uint32_t i, j, c;

	if( zi_crc_table[1] )
		return;

	for( i = 0; i < 256; i++ )
	{
		c = i;
		for( j = 0; j < 8; j++ )
			c = ( c & 1 ) ? ( 0xEDB88320u ^ ( c >> 1 )) : ( c >> 1 );
		zi_crc_table[i] = c;
	}
}

static uint32_t ZI_CRC( uint32_t crc, const uint8_t *buf, size_t len )
{
	size_t i;

	crc = ~crc;
	for( i = 0; i < len; i++ )
		crc = zi_crc_table[( crc ^ buf[i] ) & 0xFF] ^ ( crc >> 8 );
	return ~crc;
}

static uint16_t ZI_U16( const uint8_t *p )
{
	return (uint16_t)( p[0] | ( p[1] << 8 ));
}

static uint32_t ZI_U32( const uint8_t *p )
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8 ) | ((uint32_t)p[2] << 16 ) | ((uint32_t)p[3] << 24 );
}

static uint64_t ZI_U64( const uint8_t *p )
{
	return (uint64_t)ZI_U32( p ) | ((uint64_t)ZI_U32( p + 4 ) << 32 );
}

static void ZI_Error( zi_state_t *st, const char *fmt, ... ) __attribute__(( format( printf, 2, 3 )));

static void ZI_Error( zi_state_t *st, const char *fmt, ... )
{
	va_list args;

	if( !st->err || !st->errsize )
		return;

	va_start( args, fmt );
	vsnprintf( st->err, st->errsize, fmt, args );
	va_end( args );
}

static int ZI_Seek( FILE *f, uint64_t offset )
{
	return fseeko( f, (off_t)offset, SEEK_SET );
}

// mkdir -p
static int ZI_MakeDirs( const char *path )
{
	char tmp[ZI_MAX_PATH];
	size_t len = strlen( path );
	size_t i;

	if( len == 0 || len >= sizeof( tmp ))
		return -1;

	memcpy( tmp, path, len + 1 );

	for( i = 1; i <= len; i++ )
	{
		if( tmp[i] == '/' || tmp[i] == '\0' )
		{
			char saved = tmp[i];

			tmp[i] = '\0';
			if( mkdir( tmp, 0755 ) != 0 && errno != EEXIST )
				return -1;
			tmp[i] = saved;
		}
	}

	return 0;
}

// Copies a zip entry name into out as a safe relative path.
// Returns 1 for a usable path, 0 for entries to skip.
static int ZI_CleanName( const uint8_t *in, size_t len, char *out, size_t outsize )
{
	size_t i, start;

	if( len == 0 || len >= outsize )
		return 0;

	for( i = 0; i < len; i++ )
	{
		char c = (char)in[i];

		if( c == '\0' )
			return 0;
		out[i] = ( c == '\\' ) ? '/' : c;
	}
	out[len] = '\0';

	if( out[0] == '/' )
		return 0;

	// check every path component
	start = 0;
	for( i = 0; i <= len; i++ )
	{
		if( out[i] == '/' || out[i] == '\0' )
		{
			size_t clen = i - start;
			const char *comp = out + start;

			if( clen == 2 && comp[0] == '.' && comp[1] == '.' )
				return 0;
			if( clen >= 2 && comp[0] == '.' && comp[1] == '_' ) // AppleDouble metadata
				return 0;
			if( clen == 8 && !strncmp( comp, "__MACOSX", 8 ))
				return 0;
			start = i + 1;
		}
	}

	return 1;
}

static void ZI_Progress( zi_state_t *st, size_t bytes )
{
	st->done += bytes;
	if( st->progress )
		st->progress( st->ctx, st->done, st->total );
}

static int ZI_WriteAll( zi_state_t *st, FILE *out, const uint8_t *buf, size_t len, const char *path )
{
	if( len && fwrite( buf, 1, len, out ) != len )
	{
		ZI_Error( st, "couldn't write %s: %s", path, strerror( errno ));
		return -1;
	}
	return 0;
}

static int ZI_ExtractFile( zi_state_t *st, const zi_entry_t *e, const char *name, const char *path )
{
	uint8_t lh[30];
	uint64_t remaining = e->csize, written = 0;
	uint32_t crc = 0;
	FILE *out;
	int ret = 0;

	if( ZI_Seek( st->f, e->offset ) != 0 || fread( lh, 1, sizeof( lh ), st->f ) != sizeof( lh ) || ZI_U32( lh ) != ZI_SIG_LOCAL )
	{
		ZI_Error( st, "%s: damaged archive (bad local header)", name );
		return -1;
	}

	if( ZI_Seek( st->f, e->offset + sizeof( lh ) + ZI_U16( lh + 26 ) + ZI_U16( lh + 28 )) != 0 )
	{
		ZI_Error( st, "%s: damaged archive (bad data offset)", name );
		return -1;
	}

	out = fopen( path, "wb" );
	if( !out )
	{
		ZI_Error( st, "couldn't create %s: %s", path, strerror( errno ));
		return -1;
	}

	if( e->method == 0 )
	{
		while( remaining > 0 && ret == 0 )
		{
			size_t n = remaining > ZI_CHUNK ? ZI_CHUNK : (size_t)remaining;

			if( fread( st->inbuf, 1, n, st->f ) != n )
			{
				ZI_Error( st, "%s: archive is truncated", name );
				ret = -1;
				break;
			}

			crc = ZI_CRC( crc, st->inbuf, n );
			ret = ZI_WriteAll( st, out, st->inbuf, n, path );
			remaining -= n;
			written += n;
			ZI_Progress( st, n );
		}
	}
	else if( e->method == 8 )
	{
		z_stream zs;
		int zret = Z_OK;

		memset( &zs, 0, sizeof( zs ));
		if( inflateInit2( &zs, -MAX_WBITS ) != Z_OK )
		{
			ZI_Error( st, "%s: couldn't start decompression", name );
			fclose( out );
			return -1;
		}

		while( zret != Z_STREAM_END && ret == 0 )
		{
			size_t have;

			if( zs.avail_in == 0 )
			{
				size_t n = remaining > ZI_CHUNK ? ZI_CHUNK : (size_t)remaining;

				if( n == 0 )
				{
					ZI_Error( st, "%s: compressed data ends early", name );
					ret = -1;
					break;
				}

				if( fread( st->inbuf, 1, n, st->f ) != n )
				{
					ZI_Error( st, "%s: archive is truncated", name );
					ret = -1;
					break;
				}

				remaining -= n;
				zs.next_in = st->inbuf;
				zs.avail_in = (unsigned int)n;
			}

			zs.next_out = st->outbuf;
			zs.avail_out = ZI_CHUNK;
			zret = inflate( &zs, Z_NO_FLUSH );

			if( zret != Z_OK && zret != Z_STREAM_END )
			{
				ZI_Error( st, "%s: corrupt compressed data (%d)", name, zret );
				ret = -1;
				break;
			}

			have = ZI_CHUNK - zs.avail_out;
			crc = ZI_CRC( crc, st->outbuf, have );
			ret = ZI_WriteAll( st, out, st->outbuf, have, path );
			written += have;
			ZI_Progress( st, have );
		}

		inflateEnd( &zs );
	}
	else
	{
		ZI_Error( st, "%s: unsupported compression method %u (re-zip with standard settings)", name, e->method );
		ret = -1;
	}

	if( fclose( out ) != 0 && ret == 0 )
	{
		ZI_Error( st, "couldn't write %s: %s", path, strerror( errno ));
		ret = -1;
	}

	if( ret == 0 && ( written != e->usize || crc != e->crc ))
	{
		ZI_Error( st, "%s: checksum mismatch, the zip is damaged", name );
		ret = -1;
	}

	if( ret != 0 )
		remove( path );

	return ret;
}

// Finds the central directory. Returns 0 and fills count/size/offset.
static int ZI_FindCentralDir( zi_state_t *st, uint64_t filesize, uint64_t *count, uint64_t *cdsize, uint64_t *cdoffset )
{
	size_t tail = filesize < ( 65535 + 22 ) ? (size_t)filesize : ( 65535 + 22 );
	uint64_t tailstart = filesize - tail;
	uint8_t *buf;
	size_t i;
	int found = 0;
	uint64_t eocdpos = 0;

	if( tail < 22 )
	{
		ZI_Error( st, "not a zip file" );
		return -1;
	}

	buf = malloc( tail );
	if( !buf )
	{
		ZI_Error( st, "out of memory" );
		return -1;
	}

	if( ZI_Seek( st->f, tailstart ) != 0 || fread( buf, 1, tail, st->f ) != tail )
	{
		free( buf );
		ZI_Error( st, "couldn't read the zip file" );
		return -1;
	}

	for( i = tail - 22 + 1; i-- > 0; )
	{
		if( ZI_U32( buf + i ) == ZI_SIG_EOCD )
		{
			found = 1;
			eocdpos = tailstart + i;
			*count = ZI_U16( buf + i + 10 );
			*cdsize = ZI_U32( buf + i + 12 );
			*cdoffset = ZI_U32( buf + i + 16 );
			break;
		}
	}
	free( buf );

	if( !found )
	{
		ZI_Error( st, "not a zip file, or the zip is incomplete (was the copy finished?)" );
		return -1;
	}

	if( *count == 0xFFFF || *cdsize == 0xFFFFFFFFu || *cdoffset == 0xFFFFFFFFu )
	{
		uint8_t loc[20], eocd64[56];

		if( eocdpos < 20 || ZI_Seek( st->f, eocdpos - 20 ) != 0 || fread( loc, 1, sizeof( loc ), st->f ) != sizeof( loc ) || ZI_U32( loc ) != ZI_SIG_LOC64 )
		{
			ZI_Error( st, "damaged zip64 archive" );
			return -1;
		}

		if( ZI_Seek( st->f, ZI_U64( loc + 8 )) != 0 || fread( eocd64, 1, sizeof( eocd64 ), st->f ) != sizeof( eocd64 ) || ZI_U32( eocd64 ) != ZI_SIG_EOCD64 )
		{
			ZI_Error( st, "damaged zip64 archive" );
			return -1;
		}

		*count = ZI_U64( eocd64 + 32 );
		*cdsize = ZI_U64( eocd64 + 40 );
		*cdoffset = ZI_U64( eocd64 + 48 );
	}

	if( *cdoffset > filesize || *cdsize > filesize - *cdoffset || *cdsize > ( 1u << 30 ))
	{
		ZI_Error( st, "damaged zip archive (bad central directory)" );
		return -1;
	}

	return 0;
}

// Reads the zip64 extended information extra field when the 32-bit values overflowed.
static void ZI_ReadZip64Extra( const uint8_t *extra, size_t len, zi_entry_t *e, int need_usize, int need_csize, int need_offset )
{
	size_t pos = 0;

	while( pos + 4 <= len )
	{
		uint16_t id = ZI_U16( extra + pos );
		uint16_t size = ZI_U16( extra + pos + 2 );
		const uint8_t *p, *end;

		if( pos + 4 + size > len )
			break;

		p = extra + pos + 4;
		end = p + size;

		if( id == 0x0001 )
		{
			if( need_usize && p + 8 <= end ) { e->usize = ZI_U64( p ); p += 8; }
			if( need_csize && p + 8 <= end ) { e->csize = ZI_U64( p ); p += 8; }
			if( need_offset && p + 8 <= end ) { e->offset = ZI_U64( p ); }
			return;
		}

		pos += 4 + size;
	}
}

int ZipImport_Extract( const char *zippath, const char *destdir, zipimport_progress_t progress, void *ctx, char *err, size_t errsize )
{
	zi_state_t st;
	uint64_t filesize, count = 0, cdsize = 0, cdoffset = 0, n;
	uint8_t *cd = NULL;
	zi_entry_t *entries = NULL;
	size_t pos = 0, numentries = 0, i;
	char name[ZI_MAX_PATH];
	char path[ZI_MAX_PATH * 2];
	int ret = -1;

	memset( &st, 0, sizeof( st ));
	st.progress = progress;
	st.ctx = ctx;
	st.err = err;
	st.errsize = errsize;
	if( err && errsize )
		err[0] = '\0';

	ZI_InitCRC();

	st.f = fopen( zippath, "rb" );
	if( !st.f )
	{
		ZI_Error( &st, "couldn't open %s: %s", zippath, strerror( errno ));
		return -1;
	}

	if( fseeko( st.f, 0, SEEK_END ) != 0 || ftello( st.f ) < 0 )
	{
		ZI_Error( &st, "couldn't read %s", zippath );
		fclose( st.f );
		return -1;
	}
	filesize = (uint64_t)ftello( st.f );

	if( ZI_FindCentralDir( &st, filesize, &count, &cdsize, &cdoffset ) != 0 )
		goto cleanup;

	if( count > 1000000 )
	{
		ZI_Error( &st, "too many files in the zip" );
		goto cleanup;
	}

	cd = malloc( cdsize ? (size_t)cdsize : 1 );
	entries = calloc( count ? (size_t)count : 1, sizeof( *entries ));
	st.inbuf = malloc( ZI_CHUNK );
	st.outbuf = malloc( ZI_CHUNK );
	if( !cd || !entries || !st.inbuf || !st.outbuf )
	{
		ZI_Error( &st, "out of memory" );
		goto cleanup;
	}

	if( ZI_Seek( st.f, cdoffset ) != 0 || fread( cd, 1, (size_t)cdsize, st.f ) != (size_t)cdsize )
	{
		ZI_Error( &st, "couldn't read the zip's file list" );
		goto cleanup;
	}

	// parse the central directory
	for( n = 0; n < count; n++ )
	{
		zi_entry_t *e;
		uint16_t namelen, extralen, commentlen;
		uint32_t csize32, usize32, offset32;

		if( pos + 46 > cdsize || ZI_U32( cd + pos ) != ZI_SIG_CENTRAL )
		{
			ZI_Error( &st, "damaged zip archive (file list)" );
			goto cleanup;
		}

		namelen = ZI_U16( cd + pos + 28 );
		extralen = ZI_U16( cd + pos + 30 );
		commentlen = ZI_U16( cd + pos + 32 );

		if( pos + 46 + namelen + extralen + commentlen > cdsize )
		{
			ZI_Error( &st, "damaged zip archive (file list)" );
			goto cleanup;
		}

		e = &entries[numentries];
		e->flags = ZI_U16( cd + pos + 8 );
		e->method = ZI_U16( cd + pos + 10 );
		e->crc = ZI_U32( cd + pos + 16 );
		csize32 = ZI_U32( cd + pos + 20 );
		usize32 = ZI_U32( cd + pos + 24 );
		offset32 = ZI_U32( cd + pos + 42 );
		e->csize = csize32;
		e->usize = usize32;
		e->offset = offset32;

		if( csize32 == 0xFFFFFFFFu || usize32 == 0xFFFFFFFFu || offset32 == 0xFFFFFFFFu )
			ZI_ReadZip64Extra( cd + pos + 46 + namelen, extralen, e, usize32 == 0xFFFFFFFFu, csize32 == 0xFFFFFFFFu, offset32 == 0xFFFFFFFFu );

		e->nameofs = (uint32_t)( pos + 46 );
		e->namelen = namelen;

		if( ZI_CleanName( cd + pos + 46, namelen, name, sizeof( name )))
		{
			if( e->flags & 1 )
			{
				ZI_Error( &st, "%s is password protected, zip the folders without a password", name );
				goto cleanup;
			}

			st.total += e->usize;
			numentries++;
		}

		pos += 46 + namelen + extralen + commentlen;
	}

	if( ZI_MakeDirs( destdir ) != 0 )
	{
		ZI_Error( &st, "couldn't create %s: %s", destdir, strerror( errno ));
		goto cleanup;
	}

	for( i = 0; i < numentries; i++ )
	{
		const zi_entry_t *e = &entries[i];
		size_t namelen;
		char *slash;

		ZI_CleanName( cd + e->nameofs, e->namelen, name, sizeof( name ));
		namelen = strlen( name );
		snprintf( path, sizeof( path ), "%s/%s", destdir, name );

		if( name[namelen - 1] == '/' )
		{
			if( ZI_MakeDirs( path ) != 0 )
			{
				ZI_Error( &st, "couldn't create %s: %s", path, strerror( errno ));
				goto cleanup;
			}
			continue;
		}

		slash = strrchr( path, '/' );
		if( slash )
		{
			*slash = '\0';
			if( ZI_MakeDirs( path ) != 0 )
			{
				ZI_Error( &st, "couldn't create %s: %s", path, strerror( errno ));
				goto cleanup;
			}
			*slash = '/';
		}

		if( ZI_ExtractFile( &st, e, name, path ) != 0 )
			goto cleanup;
	}

	ret = 0;

cleanup:
	free( cd );
	free( entries );
	free( st.inbuf );
	free( st.outbuf );
	fclose( st.f );
	return ret;
}
