// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Small removable FAT16 answer disk, generated locally beside the user's ISO.
/// No Windows binary, product key, user credential or security bypass is embedded.
enum WindowsInstallationMedia {
    static func prepare(in directory: URL, diskSizeGiB: Int) throws {
        guard (64...512).contains(diskSizeGiB) else { throw VMLibraryError.invalidConfiguration }
        let destination = directory.appendingPathComponent("setup-support.img")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw VMLibraryError.alreadyExists(destination.lastPathComponent)
        }
        let contents = Data(answerFile.utf8)
        let sectorSize = 512
        let sectors = 16_384 // 8 MiB, with >4085 clusters (FAT16, not FAT12).
        let fatSectors = 32
        let rootSectors = 32
        let clusterBytes = 1024
        let fatOffset = sectorSize
        let rootOffset = (1 + 2 * fatSectors) * sectorSize
        let dataOffset = rootOffset + rootSectors * sectorSize
        let clusters = (contents.count + clusterBytes - 1) / clusterBytes
        var image = Data(count: sectors * sectorSize)

        func byte(_ offset: Int, _ value: UInt8) { image[offset] = value }
        func word(_ offset: Int, _ value: UInt16) {
            image[offset] = UInt8(truncatingIfNeeded: value)
            image[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func dword(_ offset: Int, _ value: UInt32) {
            word(offset, UInt16(truncatingIfNeeded: value))
            word(offset + 2, UInt16(truncatingIfNeeded: value >> 16))
        }
        func ascii(_ offset: Int, _ string: String) {
            image.replaceSubrange(offset..<(offset + string.utf8.count), with: string.utf8)
        }

        byte(0, 0xeb); byte(1, 0x3c); byte(2, 0x90)
        ascii(3, "WINIOS  ")
        word(11, 512); byte(13, 2); word(14, 1); byte(16, 2)
        word(17, 512); word(19, UInt16(sectors)); byte(21, 0xf8)
        word(22, UInt16(fatSectors)); word(24, 32); word(26, 64)
        byte(36, 0x80); byte(38, 0x29); dword(39, 0x57494f53)
        ascii(43, "WINIOSSETUP"); ascii(54, "FAT16   ")
        byte(510, 0x55); byte(511, 0xaa)

        for copy in 0..<2 {
            let base = fatOffset + copy * fatSectors * sectorSize
            word(base, 0xfff8); word(base + 2, 0xffff)
            for index in 0..<clusters {
                let cluster = index + 2
                word(base + cluster * 2, index == clusters - 1 ? 0xffff : UInt16(cluster + 1))
            }
        }
        ascii(rootOffset, "WINIOSSETUP"); byte(rootOffset + 11, 0x08)

        // Windows Setup searches for this long filename at removable-media roots.
        // Include standards-compliant VFAT entries rather than an 8.3-only alias.
        let shortName = Array("AUTOUN~1XML".utf8)
        var checksum: UInt8 = 0
        for value in shortName { checksum = ((checksum & 1) << 7) &+ (checksum >> 1) &+ value }
        let longName = Array("Autounattend.xml".utf16)
        let entryCount = (longName.count + 1 + 12) / 13
        let characterOffsets = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        for entry in 0..<entryCount {
            let ordinal = entryCount - entry
            let base = rootOffset + (entry + 1) * 32
            byte(base, UInt8(ordinal) | (ordinal == entryCount ? 0x40 : 0))
            byte(base + 11, 0x0f); byte(base + 13, checksum)
            for (position, characterOffset) in characterOffsets.enumerated() {
                let index = (ordinal - 1) * 13 + position
                let character: UInt16 = index < longName.count ? longName[index] : (index == longName.count ? 0 : 0xffff)
                word(base + characterOffset, character)
            }
        }
        let fileEntry = rootOffset + (entryCount + 1) * 32
        image.replaceSubrange(fileEntry..<(fileEntry + 11), with: shortName)
        byte(fileEntry + 11, 0x20); word(fileEntry + 16, 0x0021)
        word(fileEntry + 18, 0x0021); word(fileEntry + 24, 0x0021)
        word(fileEntry + 26, 2); dword(fileEntry + 28, UInt32(contents.count))
        image.replaceSubrange(dataOffset..<(dataOffset + contents.count), with: contents)
        try image.write(to: destination, options: .withoutOverwriting)

        // Only machines created through this flow may attach automatic answers.
        let marker = try JSONSerialization.data(withJSONObject: [
            "version": 1, "diskSizeGiB": diskSizeGiB,
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
        <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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
    </unattend>
    """
}
