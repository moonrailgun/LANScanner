//
//  LANScanner.swift
//  Pods
//
//  Created by Chris Anderson on 2/14/16.
//
//

import UIKit

//#if os(OSX)
//    import ifaddrsOSX
//#elseif os(iOS)
#if (arch(i386) || arch(x86_64))
    import ifaddrsiOSSim
    #else
    import ifaddrsiOS
#endif
//#endif

@objc public protocol LANScannerDelegate
{
    /**
     Triggered when the scanning has discovered a new device
     */
    optional func LANScannerDiscovery(device: LANDevice)
    
    /**
     Triggered when all of the scanning has finished
     */
    optional func LANScannerFinished()
    
    /**
     Triggered when the scanner starts over
     */
    optional func LANScannerRestarted()
    
    /**
     Triggered when there is an error while scanning
     */
    optional func LANScannerFailed(error: NSError)
}

public class LANScanner: NSObject {
    
    public struct NetInfo {
        let ip: String
        let netmask: String
    }
    
    
    public var delegate: LANScannerDelegate?
    public var continuous:Bool = true
    
    
    var localAddress:String?
    var baseAddress:String?
    var currentHostAddress:Int = 0
    var timer:NSTimer?
    var netMask:String?
    var baseAddressEnd:Int = 0
    var timerIterationNumber:Int = 0
    
    public override init() {
        
        super.init()
    }
    
    public init(delegate: LANScannerDelegate, continuous: Bool) {
        
        super.init()
        
        self.delegate = delegate
        self.continuous = continuous
    }
    
    // MARK: - Actions
    public func startScan() {
        
        if let localAddress = LANScanner.getLocalAddress() {
            
            self.localAddress = localAddress.ip
            self.netMask = localAddress.netmask
            
            let netMaskComponents = addressParts(self.netMask!)
            let ipComponents = addressParts(self.localAddress!)
            
            if netMaskComponents.count == 4 && ipComponents.count == 4 {
                
                for _ in 0 ..< 4 {
                    
                    self.baseAddress = "\(ipComponents[0]).\(ipComponents[1]).\(ipComponents[2])."
                    self.currentHostAddress = 0
                    self.timerIterationNumber = 0
                    self.baseAddressEnd = 255
                }
                
                self.timer = NSTimer.scheduledTimerWithTimeInterval(0.05, target: self, selector: #selector(LANScanner.pingAddress), userInfo: nil, repeats: true)
            }
        }
        else {
            
            self.delegate?.LANScannerFailed?(NSError(
                domain: "LANScanner",
                code: 101,
                userInfo: [ "error": "Unable to find a local address" ]
                )
            )
        }
    }
    
    public func stopScan() {
        
        self.timer?.invalidate()
    }
    
    
    // MARK: - Ping helpers
    func pingAddress() {
        
        self.currentHostAddress += 1
        let address:String = "\(self.baseAddress!)\(self.currentHostAddress)"
        SimplePingHelper.start(address, target: self, selector: #selector(LANScanner.pingResult(_:)))
        if self.currentHostAddress >= 254 && !continuous {
            self.timer?.invalidate()
        }
    }
    
    func pingResult(object:AnyObject) {
        
        self.timerIterationNumber += 1
        
        let success = object["status"] as! Bool
        if success {
            
            /// Send device to delegate
            let device = LANDevice()
            device.ipAddress = "\(self.baseAddress!)\(self.currentHostAddress)"
            if let hostName = LANScanner.getHostName(device.ipAddress) {
                device.hostName = hostName
            }
            
            self.delegate?.LANScannerDiscovery?(device)
        }
        
        /// When you reach the end, either restart or call it quits
        if self.timerIterationNumber >= 254 {
            
            if continuous {
                self.timerIterationNumber = 0
                self.currentHostAddress = 0
                self.delegate?.LANScannerRestarted?()
            }
            else {
                self.delegate?.LANScannerFinished?()
            }
        }
    }
    
    
    // MARK: - Network methods
    public static func getHostName(ipaddress: String) -> String? {
        
        var hostName:String? = nil
        var ifinfo: UnsafeMutablePointer<addrinfo> = nil
        
        /// Get info of the passed IP address
        if getaddrinfo(ipaddress, nil, nil, &ifinfo) == 0 {
            
            for (var ptr = ifinfo; ptr != nil; ptr = ptr.memory.ai_next) {
                
                let interface = ptr.memory
                
                /// Parse the hosname for addresses
                var hst = [CChar](count: Int(NI_MAXHOST), repeatedValue: 0)
                if (getnameinfo(interface.ai_addr, socklen_t(interface.ai_addrlen), &hst, socklen_t(hst.count),
                    nil, socklen_t(0), 0) == 0) {
                        if let address = String.fromCString(hst) {
                            hostName = address
                        }
                }
            }
            freeaddrinfo(ifinfo)
        }
        
        return hostName
    }
    
    public static func getLocalAddress() -> NetInfo? {
        var localAddress:NetInfo?
        
        /// Get list of all interfaces on the local machine:
        var ifaddr : UnsafeMutablePointer<ifaddrs> = nil
        if getifaddrs(&ifaddr) == 0 {
            
            /// For each interface ...
            for (var ptr = ifaddr; ptr != nil; ptr = ptr.memory.ifa_next) {
                let flags = Int32(ptr.memory.ifa_flags)
                let interface = ptr.memory
                var addr = interface.ifa_addr.memory
                
                /// Check for running IPv4, IPv6 interfaces. Skip the loopback interface.
                if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                    if addr.sa_family == UInt8(AF_INET) || addr.sa_family == UInt8(AF_INET6) {
                        
                        /// Narrow it down to just the wifi card
                        if let name = String.fromCString(interface.ifa_name) where name == "en0" {
                            
                            /// Convert interface address to a human readable string
                            var hostname = [CChar](count: Int(NI_MAXHOST), repeatedValue: 0)
                            if (getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST) == 0) {
                                    if let address = String.fromCString(hostname) {
                                        
                                        var net = ptr.memory.ifa_netmask.memory
                                        var netmaskName = [CChar](count: Int(NI_MAXHOST), repeatedValue: 0)
                                        getnameinfo(&net, socklen_t(net.sa_len), &netmaskName, socklen_t(netmaskName.count),
                                            nil, socklen_t(0), NI_NUMERICHOST) == 0
                                        if let netmask = String.fromCString(netmaskName) {
                                            localAddress = NetInfo(ip: address, netmask: netmask)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return localAddress
    }
    
    func addressParts(address: String) -> [String] {
        return address.componentsSeparatedByString(".")
    }
}
