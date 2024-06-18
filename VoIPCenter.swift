//
//  VoIPCenter.swift
//  flutter_ios_voip_kit
//
//  Created by 須藤将史 on 2020/07/02.
//

import Foundation
import Flutter
import PushKit
import CallKit
import AVFoundation
import UIKit

extension String {
    internal init(deviceToken: Data) {
        self = deviceToken.map { String(format: "%.2hhx", $0) }.joined()
    }
}

class VoIPCenter: NSObject {

    // MARK: - event channel

    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    private enum EventChannel: String {
        case onDidReceiveIncomingPush
        case onDidAcceptIncomingCall
        case onDidRejectIncomingCall
        
        case onDidUpdatePushToken
        case onDidActivateAudioSession
        case onDidDeactivateAudioSession
    }

    // MARK: - PushKit

    private let didUpdateTokenKey = "Did_Update_VoIP_Device_Token"
    private let pushRegistry: PKPushRegistry

    var token: String? {
        if let didUpdateDeviceToken = UserDefaults.standard.data(forKey: didUpdateTokenKey) {
            let token = String(deviceToken: didUpdateDeviceToken)
            print("🎈 VoIP didUpdateDeviceToken: \(token)")
            return token
        }

        guard let cacheDeviceToken = self.pushRegistry.pushToken(for: .voIP) else {
            return nil
        }

        let token = String(deviceToken: cacheDeviceToken)
        print("🎈 VoIP cacheDeviceToken: \(token)")
        return token
    }

    // MARK: - CallKit

    let callKitCenter: CallKitCenter
    
    fileprivate var audioSessionMode: AVAudioSession.Mode
    fileprivate let ioBufferDuration: TimeInterval
    fileprivate let audioSampleRate: Double

    init(eventChannel: FlutterEventChannel) {
        self.eventChannel = eventChannel
        self.pushRegistry = PKPushRegistry(queue: .main)
        self.pushRegistry.desiredPushTypes = [.voIP]
        self.callKitCenter = CallKitCenter()
        
        
        if let path = Bundle.main.path(forResource: "Info", ofType: "plist"), let plist = NSDictionary(contentsOfFile: path) {
            self.audioSessionMode = ((plist["FIVKAudioSessionMode"] as? String) ?? "audio") == "video" ? .videoChat : .voiceChat
            self.ioBufferDuration = plist["FIVKIOBufferDuration"] as? TimeInterval ?? 0.005
            self.audioSampleRate = plist["FIVKAudioSampleRate"] as? Double ?? 44100.0
        } else {
            self.audioSessionMode = .voiceChat
            self.ioBufferDuration = TimeInterval(0.005)
            self.audioSampleRate = 44100.0
        }
        
        super.init()
        self.eventChannel.setStreamHandler(self)
        self.pushRegistry.delegate = self
        self.callKitCenter.setup(delegate: self)
    }
}

extension VoIPCenter: PKPushRegistryDelegate {

    // MARK: - PKPushRegistryDelegate

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        print("🎈 VoIP didUpdate pushCredentials")
        UserDefaults.standard.set(pushCredentials.token, forKey: didUpdateTokenKey)
        
        self.eventSink?(["event": EventChannel.onDidUpdatePushToken.rawValue,
                         "token": pushCredentials.token.hexString])
    }

    // NOTE: iOS11 or more support

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        print("🎈 VoIP didReceiveIncomingPushWith completion: \(payload.dictionaryPayload)")

        let info = self.parse(payload: payload)
        
        let callStatus = info?["call_status"] as! String
        
        if(callStatus == "canceled"){
            self.callKitCenter.disconnected(reason: .remoteEnded)
        }else{
            let callerName = info?["incoming_caller_name"] as! String
            self.callKitCenter.incomingCall(uuidString: info?["uuid"] as! String,
                                            callerId: info?["incoming_caller_id"] as! String,
                                            callerName: callerName) { error in
                if let error = error {
                    print("❌ reportNewIncomingCall error: \(error.localizedDescription)")
                    return
                }
                self.eventSink?(["event": EventChannel.onDidReceiveIncomingPush.rawValue,
                                 "payload": info as Any,
                                 "incoming_caller_name": callerName])
                completion()
            }
        }
        
       
    }

    // NOTE: iOS10 support

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        print("🎈 VoIP didReceiveIncomingPushWith: \(payload.dictionaryPayload)")

        let info = self.parse(payload: payload)
        let callStatus = info?["call_status"] as! String
        if(callStatus == "canceled"){
            self.callKitCenter.disconnected(reason: .remoteEnded)
        }else{
            let callerName = info?["incoming_caller_name"] as! String
            self.callKitCenter.incomingCall(uuidString: info?["uuid"] as! String,
                                            callerId: info?["incoming_caller_id"] as! String,
                                            callerName: callerName) { error in
                if let error = error {
                    print("❌ reportNewIncomingCall error: \(error.localizedDescription)")
                    return
                }
                self.eventSink?(["event": EventChannel.onDidReceiveIncomingPush.rawValue,
                                 "payload": info as Any,
                                 "incoming_caller_name": callerName])
            }
        }
        
    }

    private func parse(payload: PKPushPayload) -> [String: Any]? {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload.dictionaryPayload, options: .prettyPrinted)
            let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            let aps = json?["aps"] as? [String: Any]
            return aps?["alert"] as? [String: Any]
        } catch let error as NSError {
            print("❌ VoIP parsePayload: \(error.localizedDescription)")
            return nil
        }
    }
}

extension VoIPCenter: CXProviderDelegate {

    // MARK:  - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        print("🚫 VoIP providerDidReset")
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("🤙 VoIP CXStartCallAction")
        self.callKitCenter.connectingOutgoingCall()
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("✅ VoIP CXAnswerCallAction")
        self.callKitCenter.answerCallAction = action
        
       
      
        self.configureAudioSession()
        self.eventSink?(["event": EventChannel.onDidAcceptIncomingCall.rawValue,
                         "uuid": self.callKitCenter.uuidString as Any,
                         "incoming_caller_id": self.callKitCenter.incomingCallerId as Any])
        
    }
    
    func removePrefix(from string: String, prefix: String) -> String {
        if string.hasPrefix(prefix) {
            let startIndex = string.index(string.startIndex, offsetBy: prefix.count)
            return String(string[startIndex...])
        } else {
            return string
        }
    }

    

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("❎ VoIP CXEndCallAction")

        if self.callKitCenter.isCalleeBeforeAcceptIncomingCall {
            guard let incomingCallerId = self.callKitCenter.incomingCallerId else {
                print("Error: incomingCallerId is nil")
                return
            }
            let roomId = removePrefix(from: incomingCallerId, prefix: "instant_")
            print("RoomId : \(roomId)")
            
            // Start a background task
            var backgroundTask: UIBackgroundTaskIdentifier = .invalid
            backgroundTask = UIApplication.shared.beginBackgroundTask {
                // End the task if time expires
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            
            // Update call status
            updateCallStatus(uuid: roomId, status: "rejected") {
                // End the background task
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            
            self.eventSink?(["event": EventChannel.onDidRejectIncomingCall.rawValue,
                             "uuid": self.callKitCenter.uuidString as Any,
                             "incoming_caller_id": self.callKitCenter.incomingCallerId as Any])
        }

        self.callKitCenter.disconnected(reason: .remoteEnded)
        action.fulfill()
    }

    func updateCallStatus(uuid: String, status: String, completion: @escaping () -> Void) {
        let url = URL(string: "https://apidev.karmm.com/api/v3/common/iosCallingCancel")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String: Any] = [
            "roomId": uuid,
            "status": status
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: parameters, options: .prettyPrinted)
        } catch let error {
            print("Error serializing JSON: \(error.localizedDescription)")
            completion()
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Network error: \(error.localizedDescription)")
                completion()
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                print("Invalid response")
                completion()
                return
            }

            if !(200...299).contains(httpResponse.statusCode) {
                print("Server error: HTTP \(httpResponse.statusCode)")
                completion()
                return
            }

            guard let data = data else {
                print("No data received")
                completion()
                return
            }

            do {
                let responseJSON = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                if let responseJSON = responseJSON {
                    print("Response: \(responseJSON)")
                } else {
                    print("Failed to parse JSON response")
                }
            } catch let error {
                print("Error parsing JSON response: \(error.localizedDescription)")
            }
            
            completion()
        }

        task.resume()
        print("Status Updated Successfully")
    }

    
    func updateCallStatus(uuid: String, status: String) {
        let url = URL(string: "https://apidev.karmm.com/api/v3/common/iosCallingCancel")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String: Any] = [
            "roomId": uuid,
            "status": status
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: parameters, options: .prettyPrinted)
        } catch let error {
            print("Error serializing JSON: \(error.localizedDescription)")
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Network error: \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                print("Invalid response")
                return
            }

            if !(200...299).contains(httpResponse.statusCode) {
                print("Server error: HTTP \(httpResponse.statusCode)")
                return
            }

            guard let data = data else {
                print("No data received")
                return
            }

            do {
                let responseJSON = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                if let responseJSON = responseJSON {
                    print("Response: \(responseJSON)")
                } else {
                    print("Failed to parse JSON response")
                }
            } catch let error {
                print("Error parsing JSON response: \(error.localizedDescription)")
            }
        }

        task.resume()
        print("Status Updated Succesfully")
    }

    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("🔈 VoIP didActivate audioSession")
        self.eventSink?(["event": EventChannel.onDidActivateAudioSession.rawValue])
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("🔇 VoIP didDeactivate audioSession")
        self.eventSink?(["event": EventChannel.onDidDeactivateAudioSession.rawValue])
    }
    
    // This is a workaround for known issue, when audio doesn't start from lockscreen call
    // https://stackoverflow.com/questions/55391026/no-sound-after-connecting-to-webrtc-when-app-is-launched-in-background-using-pus
    private func configureAudioSession() {
        let sharedSession = AVAudioSession.sharedInstance()
        do {
            try sharedSession.setCategory(.playAndRecord,
                                          options: [AVAudioSession.CategoryOptions.allowBluetooth,
                                                    AVAudioSession.CategoryOptions.defaultToSpeaker])
            try sharedSession.setMode(audioSessionMode)
            try sharedSession.setPreferredIOBufferDuration(ioBufferDuration)
            try sharedSession.setPreferredSampleRate(audioSampleRate)
        } catch {
            print("❌ VoIP Failed to configure `AVAudioSession`")
        }
    }
}

extension VoIPCenter: FlutterStreamHandler {

    // MARK: - FlutterStreamHandler（event channel）

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
