import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.saddle.helper", category: "HelperDelegate")

final class HelperDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard validateClient(connection) else {
            logger.warning("Rejected XPC connection from unauthorized process (pid: \(connection.processIdentifier))")
            return false
        }

        // Interface the helper exposes to the app
        connection.exportedInterface = NSXPCInterface(with: SaddleXPCProtocol.self)

        let service = DiskOperationService()
        service.clientConnection = connection
        connection.exportedObject = service

        // Interface the app exports back to the helper (for push notifications)
        connection.remoteObjectInterface = NSXPCInterface(with: SaddleXPCClientProtocol.self)

        connection.invalidationHandler = { [weak service] in
            logger.info("XPC connection invalidated (pid: \(connection.processIdentifier))")
            service?.stopMonitoring()
        }

        connection.interruptionHandler = { [weak service] in
            logger.info("XPC connection interrupted (pid: \(connection.processIdentifier))")
            service?.stopMonitoring()
        }

        connection.resume()
        logger.info("Accepted XPC connection (pid: \(connection.processIdentifier))")
        return true
    }

    // MARK: - Client Validation

    private func validateClient(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        #if DEBUG
        logger.info("DEBUG build — skipping code signature validation for pid \(pid)")
        return true
        #else
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let clientCode = code else {
            logger.error("Failed to get SecCode for pid \(pid)")
            return false
        }

        // Require the connecting app to be signed by our team with our bundle ID.
        let requirementString = """
            identifier "com.seanmandable.saddle" \
            and anchor apple generic \
            and certificate leaf[subject.OU] = "7VP76365KX"
            """

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let secReq = requirement else {
            logger.error("Failed to create security requirement")
            return false
        }

        let result = SecCodeCheckValidity(clientCode, [], secReq)
        if result != errSecSuccess {
            logger.warning("Code signature validation failed for pid \(pid): \(result)")
            return false
        }

        return true
        #endif
    }
}
