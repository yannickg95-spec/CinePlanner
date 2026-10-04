//
//  ScriptSelectionNotifications.swift
//  CinePlanner
//
//  Notifications between the script PDF and the shot's coverage card while
//  coverage is being marked.
//

import Foundation

extension Notification.Name {
    static let startScriptTextSelection = Notification.Name("startScriptTextSelection")
    static let scriptTextSelectionCompleted = Notification.Name("scriptTextSelectionCompleted")
    // The PDF coordinator tells the coverage card when selection mode turns on or
    // off; the card's Done/Cancel tell the coordinator to capture or abort. This
    // moves the instruction + buttons out of the PDF and into the card.
    static let scriptSelectionModeChanged = Notification.Name("scriptSelectionModeChanged")
    static let captureScriptSelection = Notification.Name("captureScriptSelection")
    static let cancelScriptSelection = Notification.Name("cancelScriptSelection")
    // iOS two-tap marking: the coordinator reports which word the user is picking
    // (0 = first word, 1 = last word) so the card/toolbar can update its prompt and
    // its confirm-button label ("Next" vs "Done").
    static let scriptSelectionPhaseChanged = Notification.Name("scriptSelectionPhaseChanged")
}
