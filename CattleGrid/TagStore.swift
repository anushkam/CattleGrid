//
//  TagStore.swift
//  CattleGrid
//
//  Created by Eric Betts on 4/10/20.
//  Copyright © 2020 Eric Betts. All rights reserved.
//

import Foundation
import SwiftUI
import CoreNFC
import amiitool

enum MifareCommands : UInt8 {
    case READ = 0x30
    case WRITE = 0xA2
    case PWD_AUTH = 0x1B
}

let NTAG215_SIZE = 540
let NFC3D_AMIIBO_SIZE = 520

enum NTAG215Pages : UInt8 {
    case capabilityContainer = 3
    case userMemoryFirst = 4
    case userMemoryLast = 129
    case cfg0 = 131
    case cfg1 = 132
    case pwd = 133
}

let PACK = Data([0x80, 0x80])

class TagStore : NSObject, ObservableObject, NFCTagReaderSessionDelegate {
    static let shared = TagStore()
    @Published private(set) var amiibos: [AmiiboImage] = []
    @Published private(set) var selected: AmiiboImage?

    var amiiboKeys : UnsafeMutablePointer<nfc3d_amiibo_keys> = UnsafeMutablePointer<nfc3d_amiibo_keys>.allocate(capacity: 1)
    var plain : Data = Data()

    func start() {
        print("Start")
        let fm = FileManager.default

        do {
            let items = try fm.contentsOfDirectory(at: getDocumentsDirectory(), includingPropertiesForKeys: [], options: [.skipsHiddenFiles])

            for item in items {
                //print("Found \(item)")
                amiibos.append(AmiiboImage(item))
            }
        } catch {
            // failed to read directory – bad permissions, perhaps?
        }


        let key_retail = Bundle.main.path(forResource: "key_retail", ofType: "bin")!
        if (!nfc3d_amiibo_load_keys(amiiboKeys, key_retail)) {
            print("Could not load keys from \(key_retail)")
            return
        }
        //print(amiiboKeys.pointee.data)
    }

    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }

    func load(_ amiibo: AmiiboImage) {
        do {
            let tag = try Data(contentsOf: amiibo.path)
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: NTAG215_SIZE)

            let unsafeDump : UnsafePointer<UInt8> = tag.withUnsafeBytes { bytes in
                return bytes
            }

            if (!nfc3d_amiibo_unpack(amiiboKeys, unsafeDump, output)) {
                print("!!! WARNING !!!: Tag signature was NOT valid")
            }

            plain = Data(bytes: output, count: tag.count)
            print("\(amiibo.filename) selected")
            self.selected = amiibo
            // print("Unpacked: \(plain.hexDescription)")
        } catch {
            print("Couldn't read file \(amiibo.path)")
        }
    }

    func scan() {
        print("Scan")

        guard NFCReaderSession.readingAvailable else {
            print("NFCReaderSession.readingAvailable failed")
            return
        }

        if let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil) {
            session.alertMessage = "Hold your device near a tag to write."
            session.begin()
        }
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        print("reader active \(session)")
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        print("didInvalidateWithError: \(error.localizedDescription)")
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        print("didDetect: \(tags)")

        if case let NFCTag.miFare(tag) = tags.first! {
            guard tag.mifareFamily == .ultralight else {
                print("Ignoring non-ultralight \(tag.mifareFamily.rawValue)")
                return
            }

            session.connect(to: tags.first!) { (error: Error?) in
                if ((error) != nil) {
                    print(error as Any)
                    return
                }

                self.connected(tag)
            }
        } else {
            print("Ignoring non-mifare tag")
        }
    }

    func connected(_ tag: NFCMiFareTag) {
        let read = Data([MifareCommands.READ.rawValue, 0])
        tag.sendMiFareCommand(commandPacket: read) { (data, error) in
            if ((error) != nil) {
                print(error as Any)
                return
            }

            // let uid = data.subdata(in: 0..<7)
            //TODO: valudate CC is correct for blank tag.
            //let cc = data.subdata(in: 12..<16) // amiibo: f1 10 ff ee
            //print("cc = \(cc.hexDescription)")


            //Amiitool plain text stores first 2 pages (uid) towards the end
            self.plain.replaceSubrange(468..<476, with: data.subdata(in: 0..<8))

            let newImage = UnsafeMutablePointer<UInt8>.allocate(capacity: NTAG215_SIZE)

            let unsafePlain : UnsafePointer<UInt8> = self.plain.withUnsafeBytes { bytes in
                return bytes
            }

            nfc3d_amiibo_pack(self.amiiboKeys, unsafePlain, newImage)

            let new = Data(bytes: newImage, count: NTAG215_SIZE)
            //print(new.hexDescription)

            self.writeTag(tag, newImage: new) { () in
                print("done writing")
            }

        }
    }

    func writeTag(_ tag: NFCMiFareTag, newImage: Data, completionHandler: @escaping () -> Void) {
        self.writeUserPages(tag, startPage: NTAG215Pages.userMemoryFirst.rawValue, data: newImage, completionHandler: completionHandler)
        //write CC
        //write PWD
        //let pwd = self.calculatePWD(tag.identifier)
        //write PACK
        //etc
    }

    func writeUserPages(_ tag: NFCMiFareTag, startPage: UInt8, data: Data, completionHandler: @escaping () -> Void) {
        if (startPage > NTAG215Pages.userMemoryLast.rawValue) {
            completionHandler()
            return
        }

        let page = data.subdata(in: Int(startPage) * 4 ..< Int(startPage) * 4 + 4)

        print("Write page \(startPage) \(page.hexDescription)")
        let write = addChecksum(Data([MifareCommands.WRITE.rawValue, startPage]) + page)
        tag.sendMiFareCommand(commandPacket: write) { (data, error) in
            if ((error) != nil) {
                print("Error during write: \(error as Any)")
                return
            }
            self.writeUserPages(tag, startPage: startPage+1, data: data) { () in
                completionHandler()
            }
        }
    }

    func addChecksum(_ data: Data) -> Data {
        var crc = crc16ccitt([UInt8](data))
        return data + Data(bytes: &crc, count: MemoryLayout<UInt16>.size)
    }

    func crc16ccitt(_ data: [UInt8], seed: UInt16 = 0x6363, final: UInt16 = 0xffff)-> UInt16 {
        var crc = seed
        data.forEach { (byte) in
            crc ^= UInt16(byte) << 8
            (0..<8).forEach({ _ in
                crc = (crc & UInt16(0x8000)) != 0 ? (crc << 1) ^ 0x8408 : crc << 1
            })
        }
        return UInt16(crc & final)
    }

    func dumpTag(_ tag: NFCMiFareTag, completionHandler: @escaping (Data) -> Void) {
        self.readAllPages(tag, startPage: 0, completionHandler: completionHandler)
    }

    func readAllPages(_ tag: NFCMiFareTag, startPage: UInt8, completionHandler: @escaping (Data) -> Void) {
        if (startPage > 129) {
            completionHandler(Data())
            return
        }
        print("Read page \(startPage)")
        let read = Data([MifareCommands.READ.rawValue, startPage])
        tag.sendMiFareCommand(commandPacket: read) { (data, error) in
            if ((error) != nil) {
                print(error as Any)
                return
            }
            self.readAllPages(tag, startPage: startPage+4) { (contents) in
                completionHandler(data + contents)
            }
        }
    }

    func calculatePWD(_ uid: Data) -> Data {
        print(uid.hexDescription)
        var PWD = Data(count: 4)
        PWD[0] = uid[1] ^ uid[3] ^ 0xAA
        PWD[1] = uid[2] ^ uid[4] ^ 0x55
        PWD[2] = uid[3] ^ uid[5] ^ 0xAA
        PWD[3] = uid[4] ^ uid[6] ^ 0x55
        return PWD
    }


}
