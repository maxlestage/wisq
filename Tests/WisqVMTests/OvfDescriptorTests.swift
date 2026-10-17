import XCTest
@testable import WisqVM

/// La seule question posée au descripteur OVF : sur quel fichier
/// l'appliance démarre.
final class OvfDescriptorTests: XCTestCase {

    private func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
                  xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
                  xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData">
          <References>
            <File ovf:id="file1" ovf:href="donnees.vmdk"/>
            <File ovf:id="file2" ovf:href="systeme.vmdk"/>
          </References>
          <DiskSection>
            <Disk ovf:diskId="vmdisk1" ovf:fileRef="file1"/>
            <Disk ovf:diskId="vmdisk2" ovf:fileRef="file2"/>
          </DiskSection>
          \(body)
        </Envelope>
        """
    }

    private func disk(_ host: String, type: String = "17") -> String {
        """
        <Item>
          <rasd:HostResource>\(host)</rasd:HostResource>
          <rasd:ResourceType>\(type)</rasd:ResourceType>
        </Item>
        """
    }

    /// Le premier disque **branché** l'emporte sur le premier déclaré — et
    /// les deux graphies de la ressource, celle de VMware (`ovf:/disk/`) et
    /// celle de VirtualBox (`/disk/`), se lisent pareil.
    func testTheFirstAttachedDiskWins() {
        for prefix in ["ovf:/disk/", "/disk/"] {
            let text = envelope("<VirtualHardwareSection>"
                + disk(prefix + "vmdisk2") + disk(prefix + "vmdisk1") + "</VirtualHardwareSection>")
            XCTAssertEqual(OvfDescriptor.bootDiskHref(text), "systeme.vmdk", prefix)
        }
    }

    /// Ce qui n'est pas un disque branché ne compte pas : un lecteur de CD
    /// (type 15), un disque désigné par fichier plutôt que par `DiskSection`,
    /// une ressource vers un disque qui n'existe pas.
    func testWhatIsNotAnAttachedDiskIsSkipped() {
        let text = envelope("<VirtualHardwareSection>"
            + disk("/disk/vmdisk1", type: "15")
            + disk("ovf:/file/file1")
            + disk("/disk/inconnu")
            + disk("/disk/vmdisk2")
            + "</VirtualHardwareSection>")
        XCTAssertEqual(OvfDescriptor.bootDiskHref(text), "systeme.vmdk")
    }

    /// Sans matériel qui en branche un, le premier disque déclaré ; sans
    /// disque déclaré, rien — l'archive garde alors son premier VMDK.
    func testWithoutHardwareTheFirstDeclaredDiskAndWithoutDisksNothing() {
        XCTAssertEqual(OvfDescriptor.bootDiskHref(envelope("")), "donnees.vmdk")
        XCTAssertNil(OvfDescriptor.bootDiskHref("<Envelope><References/></Envelope>"))
        XCTAssertNil(OvfDescriptor.bootDiskHref("pas du XML du tout"))
        XCTAssertNil(OvfDescriptor.bootDiskHref(""))
    }

    /// Ce que le XML permet et qu'un OVF peut contenir : un commentaire qui
    /// contient des balises, un `>` dans une valeur entre guillemets, des
    /// apostrophes au lieu de guillemets, une entité dans le nom de fichier,
    /// un `Item` vide refermé sur lui-même, une ressource sur plusieurs
    /// lignes.
    func testTheXMLAnOVFCanContainIsRead() {
        let text = """
            <Envelope>
              <References>
                <File ovf:id="file0" ovf:href="autre.vmdk"/>
                <File ovf:size="a>b" ovf:id='file1' ovf:href='d&amp;d.vmdk'/>
              </References>
              <!-- un > nu, puis <File ovf:id="file1" ovf:href="leurre.vmdk"/> -->
              <DiskSection>
                <Disk ovf:diskId="d0" ovf:fileRef="file0"/>
                <Disk ovf:diskId="d1" ovf:fileRef="file1"/>
              </DiskSection>
              <VirtualHardwareSection>
                <Item/>
                <Item><rasd:ResourceType>17</rasd:ResourceType><rasd:HostResource>
                  ovf:/disk/d1
                </rasd:HostResource></Item>
              </VirtualHardwareSection>
            </Envelope>
            """
        XCTAssertEqual(OvfDescriptor.bootDiskHref(text), "d&d.vmdk")
    }
}
