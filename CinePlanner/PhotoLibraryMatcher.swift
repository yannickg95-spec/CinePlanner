//
//  PhotoLibraryMatcher.swift
//  CineStager 2
//
//  Helper for finding matching photos in the user's photo library
//

import Foundation
import Photos
import PhotosUI
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
class PhotoLibraryMatcher {
    
    /// Search for a photo in the library with a matching Capture ID
    /// Searches only photos taken on the same day as the reference photo for better performance
    static func findMatchingPhoto(for captureID: String, excludingData: Data? = nil, creationDate: Date? = nil) async -> Data? {
        // Request photo library authorization if needed
        let status = await requestPhotoLibraryAccess()
        guard status == .authorized || status == .limited else {
            Log.photos.notice("⚠️ Photo library access not authorized. Status: \(status.rawValue)")
            return nil
        }
        
        if status == .limited {
            Log.photos.notice("⚠️ Photo library access is limited - can only search user-selected photos")
            Log.photos.debug("💡 For full auto-matching, user needs to grant 'All Photos' access in Settings")
        }
        
        Log.photos.debug("🔍 Searching photo library for Capture ID: \(captureID)")
        
        // Fetch photos from the same day as the selected photo
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // If we have a creation date, search only photos from the same day
        if let referenceDate = creationDate {
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: referenceDate)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? referenceDate
            
            fetchOptions.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                startOfDay as NSDate,
                endOfDay as NSDate
            )
            
            Log.photos.debug("📅 Searching photos from same day: \(DateFormatter.localizedString(from: referenceDate, dateStyle: .medium, timeStyle: .none))")
        } else {
            // Fallback: search last 7 days if no date provided
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            fetchOptions.predicate = NSPredicate(format: "creationDate > %@", sevenDaysAgo as NSDate)
            Log.photos.debug("ℹ️ No reference date provided, searching last 7 days")
        }
        
        let allPhotos = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        
        Log.photos.debug("📷 Found \(allPhotos.count) photos to search...")
        
        if allPhotos.count == 0 {
            Log.photos.error("❌ No photos found - this may be due to limited photo library access")
            return nil
        }
        
        // Search for matching photo
        return await withCheckedContinuation { continuation in
            var found = false
            var searchedCount = 0
            
            allPhotos.enumerateObjects { asset, index, stop in
                guard !found else {
                    stop.pointee = true
                    return
                }
                
                searchedCount += 1
                
                // Request image data to check metadata
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                options.deliveryMode = .fastFormat // Use fast format for searching
                options.isNetworkAccessAllowed = false // Don't download from iCloud during search
                
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    guard let imageData = data else { return }
                    
                    // Skip if this is the same photo we just loaded
                    if let excludingData = excludingData, imageData == excludingData {
                        return
                    }
                    
                    // Extract metadata quickly
                    if let metadata = EXIFExtractor.extractMetadata(from: imageData) {
                        if metadata.captureID == captureID {
                            Log.photos.debug("✅ Found matching photo at index \(index) (type: \(metadata.captureType ?? "unknown"))")
                            found = true
                            stop.pointee = true
                            
                            // Now load the full quality version
                            Task {
                                if let fullData = await loadImageData(from: asset) {
                                    continuation.resume(returning: fullData)
                                } else {
                                    continuation.resume(returning: nil)
                                }
                            }
                        }
                    }
                }
            }
            
            // If we didn't find a match after searching
            if !found {
                Log.photos.error("❌ No matching photo found in \(searchedCount) photos searched")
                continuation.resume(returning: nil)
            }
        }
    }
    
    /// Request photo library access
    private static func requestPhotoLibraryAccess() async -> PHAuthorizationStatus {
        // Check current authorization status
        #if os(iOS) || os(iPadOS)
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        if status == .notDetermined {
            // Request full library access
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return newStatus
        }
        
        // If limited, we should inform the user or prompt to change settings
        if status == .limited {
            Log.photos.notice("⚠️ Photo library access is limited. Full access needed for auto-matching.")
            Log.photos.debug("💡 User can grant full access in Settings > Privacy > Photos")
        }
        
        return status
        #else
        // macOS
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        if status == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        
        return status
        #endif
    }
    
    /// Load full image data from a PHAsset
    private static func loadImageData(from asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
