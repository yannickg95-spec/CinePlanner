//
//  Log.swift
//  CinePlanner
//
//  Logging for the app's noisier subsystems.
//
//  These replaced plain `print` calls, which ran in release builds too: they cost
//  time inside export loops and wrote scene names, shot names and file paths to
//  the system console. `Logger` fixes both. A `.debug` message is off unless
//  someone turns it on, and when it is off the interpolations are never even
//  evaluated. Dynamic strings are redacted by default, so a scene heading shows
//  as <private> to anyone reading the console; numbers stay visible, which keeps
//  counts and indices useful while debugging.
//
//  Filter by subsystem in Console.app to follow one area.
//

import os

enum Log {
    private static let subsystem = "com.YannickGiraud.CinePlanner"

    /// Reading EXIF/TIFF/IPTC out of reference stills.
    static let exif = Logger(subsystem: subsystem, category: "exif")
    /// PDF, web, text and archive export.
    static let export = Logger(subsystem: subsystem, category: "export")
    /// Script import, scene detection and coverage marking.
    static let script = Logger(subsystem: subsystem, category: "script")
    /// Matching reference stills against the photo library.
    static let photos = Logger(subsystem: subsystem, category: "photos")
    /// The scene map editor.
    static let sceneMap = Logger(subsystem: subsystem, category: "sceneMap")
    /// Bringing in shots from CineStager and Cadrage.
    static let importer = Logger(subsystem: subsystem, category: "import")
    /// Everything else in the app shell.
    static let app = Logger(subsystem: subsystem, category: "app")
}
