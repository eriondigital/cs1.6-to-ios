/*
 zipimport.h - unpacks the player's game zips (valve.zip, cstrike.zip, ...)
 Copyright (C) 2026 cs1.6-to-ios contributors

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
*/
#ifndef ZIPIMPORT_H
#define ZIPIMPORT_H

#include <stddef.h>

// called from the extracting thread; done/total are uncompressed bytes
typedef void (*zipimport_progress_t)( void *ctx, unsigned long long done, unsigned long long total );

// Extracts every file of a zip archive (stored or deflated, zip64 aware) into destdir,
// keeping the archive's folder structure. Skips unsafe paths ("..", absolute) and macOS
// metadata (__MACOSX, ._*). Each file's CRC is checked.
// Returns 0 on success, -1 on failure with a readable reason in err.
int ZipImport_Extract( const char *zippath, const char *destdir, zipimport_progress_t progress, void *ctx, char *err, size_t errsize );

#endif // ZIPIMPORT_H
