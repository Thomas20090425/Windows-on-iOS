// SPDX-License-Identifier: GPL-2.0-or-later
// Host-only fixtures for the actual native configuration and UTM bundle save logic.
import Foundation
@main struct NativeConfigurationChecks {
 @MainActor static func main() async throws {
  let fm=FileManager.default
  let root=fm.temporaryDirectory.appendingPathComponent("utm-native-model-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? fm.removeItem(at:root)}
  func put(_ url:URL,_ text:String) throws {
   try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
   try Data(text.utf8).write(to:url)
  }
  func verify(_ condition:Bool,_ text:String) throws {if !condition {throw UTMNativeError.message(text)}}
  let win=root.appendingPathComponent("original-windows")
  let winFiles=["windows11.img":"disk-bytes","vars.fd":"nvram-bytes","TPM/identity":"tpm-id","TPM/permall":"tpm-state","tpm-state-initialized":"WindowsiOS TPM 2.0 identity initialized\n","nested/preserve.state":"keep-all-state"]
  for (name,bytes) in winFiles {try put(win.appendingPathComponent(name),bytes)}
  let wc=UTMNativeConfiguration(engine:.windows);wc.information.name="Windows";wc.machineImportURL=win
  let wp=root.appendingPathComponent("Windows.utm")
  try await wc.save(to:wp)
  for (name,bytes) in winFiles {
   try verify(try Data(contentsOf:wp.appendingPathComponent("Data/"+name))==Data(bytes.utf8),"Windows imported state changed: "+name)
   try verify(fm.fileExists(atPath:win.appendingPathComponent(name).path),"Windows source removed")
  }
  let windowsMemory=min(6144,wc.maximumMemoryMiB)
  wc.memoryMiB=windowsMemory
  try put(wp.appendingPathComponent("Data/unlisted-engine.state"),"preserve-unknown")
  try await wc.save(to:wp)
  for (name,bytes) in winFiles {try verify(try Data(contentsOf:wp.appendingPathComponent("Data/"+name))==Data(bytes.utf8),"UTM cleanup deleted Windows state")}
  try verify(fm.fileExists(atPath:wp.appendingPathComponent("Data/unlisted-engine.state").path),"Unknown engine state deleted")
  let decoded=try PropertyListDecoder().decode(UTMNativeConfiguration.self,from:Data(contentsOf:wp.appendingPathComponent("config.plist")))
  try verify(decoded.memoryMiB==windowsMemory && decoded.information.uuid==wc.information.uuid,"Config roundtrip lost RAM/identity")
  try verify(wc.maximumMemoryMiB==min(16384,max(0,Int(ProcessInfo.processInfo.physicalMemory >> 20)-3072)),"Device RAM limit does not leave required headroom")
  print("PASS Windows full-folder import, retained source, TPM/NVRAM and unknown-state preservation, RAM roundtrip")
  let mac=root.appendingPathComponent("original-mac")
  let macFiles=["disk.img":"mac-disk","auxiliary.bin":"aux-keys","AVPBooter.vmapple2.bin":"rom-bytes","machine.json":"{\"ecid\":123456789123456,\"seed\":98765}","installed":"macOS","restore/partial":"restore-state"]
  for (name,bytes) in macFiles {try put(mac.appendingPathComponent(name),bytes)}
  let mc=UTMNativeConfiguration(engine:.macOS);mc.information.name="Mac";mc.machineImportURL=mac
  let mp=root.appendingPathComponent("Mac.utm")
  try await mc.save(to:mp);mc.memoryMiB=min(8192,mc.maximumMemoryMiB);try await mc.save(to:mp)
  for (name,bytes) in macFiles {try verify(try Data(contentsOf:mp.appendingPathComponent("Data/Henge/"+name))==Data(bytes.utf8),"Henge identity or auxiliary state changed: "+name)}
  print("PASS Henge full-folder import, ECID/seed metadata, auxiliary storage and restore-state preservation")
  func expectFailure(_ config:UTMNativeConfiguration,_ package:String) async throws {
   var rejected=false
   do {try await config.save(to:root.appendingPathComponent(package+".utm"))} catch {rejected=true}
   try verify(rejected,"Expected rejection: "+package)
   try verify(!fm.fileExists(atPath:root.appendingPathComponent(package+".utm/config.plist").path),"Failed import was published")
  }
  let brokenWin=root.appendingPathComponent("broken-windows")
  for name in ["windows11.img","vars.fd","tpm-state-initialized","TPM/identity"] {try put(brokenWin.appendingPathComponent(name),"state")}
  let bw=UTMNativeConfiguration(engine:.windows);bw.machineImportURL=brokenWin
  try await expectFailure(bw,"reject-tpm-loss")
  let brokenMac=root.appendingPathComponent("broken-mac")
  for name in ["disk.img","auxiliary.bin","AVPBooter.vmapple2.bin"] {try put(brokenMac.appendingPathComponent(name),"state")}
  let bm=UTMNativeConfiguration(engine:.macOS);bm.machineImportURL=brokenMac
  try await expectFailure(bm,"reject-missing-ecid")
  try put(brokenMac.appendingPathComponent("machine.json"),"{\"ecid\":true}")
  try await expectFailure(bm,"reject-invalid-ecid")
  let symbolic=root.appendingPathComponent("symlink-windows")
  try fm.copyItem(at:win,to:symbolic)
  try fm.createSymbolicLink(at:symbolic.appendingPathComponent("external-state"),withDestinationURL:win)
  let sc=UTMNativeConfiguration(engine:.windows);sc.machineImportURL=symbolic
  try await expectFailure(sc,"reject-symbolic-links")
  let ancestor=UTMNativeConfiguration(engine:.windows);ancestor.machineImportURL=win
  var ancestorRejected=false
  do {try await ancestor.save(to:win.appendingPathComponent("nested-destination.utm"))} catch {ancestorRejected=true}
  try verify(ancestorRejected,"Recursive source/destination import was accepted")
  let invalid=UTMNativeConfiguration(engine:.windows);invalid.memoryMiB=0
  try await expectFailure(invalid,"reject-invalid-ram")
  invalid.memoryMiB=invalid.maximumMemoryMiB+1
  try await expectFailure(invalid,"reject-over-device-ram-limit")
  let originalConfig=try Data(contentsOf:wp.appendingPathComponent("config.plist"))
  wc.memoryMiB=0
  var invalidExistingRejected=false
  do {try await wc.save(to:wp)} catch {invalidExistingRejected=true}
  try verify(invalidExistingRejected,"Invalid existing configuration was saved")
  try verify(try Data(contentsOf:wp.appendingPathComponent("config.plist"))==originalConfig,"Failed RAM validation modified existing configuration")
  try verify(try Data(contentsOf:wp.appendingPathComponent("Data/TPM/permall"))==Data("tpm-state".utf8),"Failed save modified guest TPM")
  wc.memoryMiB=windowsMemory
  print("PASS missing TPM/identity, corrupt ECID, symlink, recursive import and invalid RAM error paths")
  let media=root.appendingPathComponent("new.iso");try put(media,"new-installer")
  wc.mediaImportURL=media;try await wc.save(to:wp)
  try verify(try Data(contentsOf:wp.appendingPathComponent("Data/installer.iso"))==Data("new-installer".utf8),"Media not copied")
  try put(media,"replacement-installer");wc.mediaImportURL=media;try await wc.save(to:wp)
  try verify(try Data(contentsOf:wp.appendingPathComponent("Data/installer.iso"))==Data("replacement-installer".utf8),"Media not replaced")
  try verify(try Data(contentsOf:wp.appendingPathComponent("Data/TPM/permall"))==Data("tpm-state".utf8),"Media replacement touched TPM")
  print("PASS installation media replacement leaves guest disk and TPM state intact")
 }
}
