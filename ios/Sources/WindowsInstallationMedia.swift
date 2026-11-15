// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

/// Private FAT16 setup/driver disk beside the user's ISO. Bundled signed ARM64
/// drivers are retained; no Windows image, product key or credential is embedded.
enum WindowsInstallationMedia {
    static func prepare(in directory: URL, diskSizeGiB: Int) throws {
        guard (64...512).contains(diskSizeGiB) else { throw VMLibraryError.invalidConfiguration }
        let destination = directory.appendingPathComponent("setup-support.img")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw VMLibraryError.alreadyExists(destination.lastPathComponent)
        }
        guard let driverURL = VMBundledDrivers.imageURL, let manifestURL = VMBundledDrivers.manifestURL,
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              let slot = manifest["answer_slot"] as? [String: Any],
              let expectedHash = manifest["image_sha256"] as? String else { throw VMLibraryError.missingBundledDrivers }
        var image = try Data(contentsOf: driverURL)
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash, image.count == 64 * 1024 * 1024,
              let rootOffset = (slot["root_entry_offset"] as? NSNumber)?.intValue,
              let dataOffset = (slot["data_offset"] as? NSNumber)?.intValue,
              let clusterBytes = (slot["cluster_bytes"] as? NSNumber)?.intValue,
              let firstCluster = (slot["first_cluster"] as? NSNumber)?.intValue,
              let maximum = (slot["max_bytes"] as? NSNumber)?.intValue,
              let fatNumbers = slot["fat_offsets"] as? [NSNumber], fatNumbers.count == 2,
              rootOffset >= 512, rootOffset <= image.count - 96,
              maximum == 65536, dataOffset >= 512, dataOffset <= image.count - maximum,
              [1024, 2048, 4096].contains(clusterBytes), firstCluster >= 2,
              firstCluster + maximum / clusterBytes < 65525 else { throw VMLibraryError.missingBundledDrivers }
        let contents = Data(answerFile.utf8)
        guard !contents.isEmpty, contents.count <= maximum else { throw VMLibraryError.missingBundledDrivers }
        let clusters = (contents.count + clusterBytes - 1) / clusterBytes
        func word(_ offset: Int, _ value: UInt16) {
            image[offset] = UInt8(truncatingIfNeeded: value)
            image[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func dword(_ offset: Int, _ value: UInt32) {
            word(offset, UInt16(truncatingIfNeeded: value))
            word(offset + 2, UInt16(truncatingIfNeeded: value >> 16))
        }
        // The checked build-time image reserves CONFIG.BIN and two adjacent
        // deleted directory entries for this private VM's answer file. Other
        // driver files and their signed package bytes remain unchanged.
        for number in fatNumbers {
            let fat = number.intValue
            guard fat >= 512, fat <= image.count - (firstCluster + maximum / clusterBytes + 1) * 2 else {
                throw VMLibraryError.missingBundledDrivers
            }
            for index in 0..<(maximum / clusterBytes) {
                let next = index >= clusters ? 0 : index == clusters - 1 ? 0xffff : firstCluster + index + 1
                word(fat + (firstCluster + index) * 2, UInt16(next))
            }
        }
        image.replaceSubrange(rootOffset..<(rootOffset + 96), with: Data(count: 96))
        let shortName = Array("AUTOUN~1XML".utf8)
        var checksum: UInt8 = 0
        for value in shortName { checksum = ((checksum & 1) << 7) &+ (checksum >> 1) &+ value }
        let longName = Array("Autounattend.xml".utf16)
        let characterOffsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        for entry in 0..<2 {
            let ordinal = 2 - entry
            let base = rootOffset + entry * 32
            image[base] = UInt8(ordinal) | (ordinal == 2 ? 0x40 : 0)
            image[base + 11] = 0x0f; image[base + 13] = checksum
            for (position, characterOffset) in characterOffsets.enumerated() {
                let index = (ordinal - 1) * 13 + position
                word(base + characterOffset, index < longName.count ? longName[index] : (index == longName.count ? 0 : 0xffff))
            }
        }
        let fileEntry = rootOffset + 64
        image.replaceSubrange(fileEntry..<(fileEntry + 11), with: shortName)
        image[fileEntry + 11] = 0x20
        word(fileEntry + 16, 0x0021); word(fileEntry + 18, 0x0021); word(fileEntry + 24, 0x0021)
        word(fileEntry + 26, UInt16(firstCluster)); dword(fileEntry + 28, UInt32(contents.count))
        image.replaceSubrange(dataOffset..<(dataOffset + maximum), with: Data(count: maximum))
        image.replaceSubrange(dataOffset..<(dataOffset + contents.count), with: contents)
        try image.write(to: destination, options: .withoutOverwriting)

        // Only machines created through this flow may attach automatic answers.
        let marker = try JSONSerialization.data(withJSONObject: [
            "version": 2, "diskSizeGiB": diskSizeGiB,
            "target": "windows11.img", "imageIndex": 1
        ], options: [.sortedKeys])
        try marker.write(to: directory.appendingPathComponent("installation-created.json"), options: .withoutOverwriting)
    }

    /// Only a new blank app-created target receives this answer file. Native
    /// startup and warm-reset guards remove automatic answers after partitioning.
    /// WillWipeDisk is false as an additional safeguard; existing VMs are never reset.
    private static let answerFile = """
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>%configsetroot%\\Drivers\\NetKVM</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>%configsetroot%\\Drivers\\Display</Path></PathAndCredentials>
          </DriverPaths>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <UseConfigurationSet>true</UseConfigurationSet>
          <DiskConfiguration>
            <Disk wcm:action="add">
              <DiskID>0</DiskID>
              <WillWipeDisk>false</WillWipeDisk>
              <CreatePartitions>
                <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
                <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
              </CreatePartitions>
              <ModifyPartitions>
                <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
              </ModifyPartitions>
            </Disk>
            <WillShowUI>OnError</WillShowUI>
          </DiskConfiguration>
          <ImageInstall>
            <OSImage>
              <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom>
              <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
              <WillShowUI>OnError</WillShowUI>
            </OSImage>
          </ImageInstall>
          <UserData><AcceptEula>true</AcceptEula></UserData>
        </component>
      </settings>
      <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order><Description>Install bundled WindowsiOS network and display drivers</Description>
              <Path>cmd.exe /c for %D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %D:\\WINIOSDRIVERS.TAG (call "%D:\\InstallDrivers.cmd" /setup &amp; exit /b 0)</Path>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
    </unattend>
    """
}
