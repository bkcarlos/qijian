#if targetEnvironment(simulator) && DEBUG
import Foundation

/// Simulator-only visual fixtures; never included in a physical-device build.
enum MobileDemo {
    static func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
    static let values: [String: Any] = [id(101): true, id(201): false, id(202): 65, id(301): 1, id(302): 24.0, id(303): 26.0, id(401): 24.0, id(402): 42.0]
    static func characteristic(_ n: Int, _ code: String, _ name: String, _ writable: Bool, _ format: String, _ units: String? = nil) -> [String: Any] {
        var metadata: [String: Any] = ["format": format]
        if let units { metadata["units"] = units }
        if code == "00000008" { metadata["minimum"] = 0; metadata["maximum"] = 100; metadata["step"] = 1 }
        if code == "00000035" { metadata["minimum"] = 16; metadata["maximum"] = 30; metadata["step"] = 0.5 }
        if code == "000000B0" { metadata["validValues"] = [0,1] }
        return ["id": id(n), "type": "\(code)-0000-1000-8000-0026BB765291", "description": name, "readable": true, "hardwareWritable": writable, "metadata": metadata]
    }
    static func device(_ n: Int, _ name: String, _ room: Int, _ roomName: String, _ type: String, _ chars: [[String: Any]]) -> [String: Any] {
        ["id": id(n), "name": name, "homeId": id(1), "roomId": id(room), "roomName": roomName, "reachable": true,
         "services": [["id": id(n+500), "name": name, "typeName": type, "primary": true, "userInteractive": true, "characteristics": chars]]]
    }
    static var snapshot: [String: Any] {
        let devices = [
            device(10,"厨房灯",2,"厨房","light",[characteristic(101,"00000025","电源",true,"bool")]),
            device(20,"客厅落地灯",3,"客厅","light",[characteristic(201,"00000025","电源",true,"bool"),characteristic(202,"00000008","亮度",true,"int")]),
            device(30,"卧室空调",4,"卧室","heater_cooler",[characteristic(301,"000000B0","运行",true,"uint8"),characteristic(302,"00000011","当前温度",false,"float","celsius"),characteristic(303,"00000035","目标温度",true,"float","celsius")]),
            device(40,"温湿度计",3,"客厅","sensor",[characteristic(401,"00000011","温度",false,"float","celsius"),characteristic(402,"00000010","湿度",false,"float","percentage")])
        ]
        let rooms: [[String: Any]] = [(2,"厨房",1),(3,"客厅",2),(4,"卧室",1)].map { ["id":id($0.0),"homeId":id(1),"name":$0.1,"isDefault":false,"accessoryCount":$0.2] }
        let actions: [[String: Any]] = [["id":id(901),"kind":"characteristic_write","characteristicId":id(101),"value":false],["id":id(902),"kind":"characteristic_write","characteristicId":id(201),"value":false]]
        let scenes: [[String: Any]] = [["id":id(900),"homeId":id(1),"name":"准备睡觉","userDefined":true,"actionCount":2,"actions":actions]]
        return ["metadata":["authorization":"authorized","loaded":true],"homes":[["id":id(1),"name":"林间小屋","rooms":rooms,"accessories":devices,"scenes":scenes]]]
    }
    static func layout() -> FloorPlanLayout {
        var result = FloorPlanLayout(homeID:id(1)); var spatial = SpatialLayout()
        func room(_ n: Int,_ name: String,_ x: Double,_ y: Double,_ w: Double,_ h: Double) -> SpatialRoom {
            SpatialRoom(id:id(n),name:name,points:[PlanPoint(x:x,y:y),PlanPoint(x:x+w,y:y),PlanPoint(x:x+w,y:y+h),PlanPoint(x:x,y:y+h)])
        }
        spatial.rooms = [room(2,"厨房",0.1,0.1,0.35,0.35),room(3,"客厅",0.45,0.1,0.4,0.75),room(4,"卧室",0.1,0.45,0.35,0.4)]
        spatial.furniture = [SpatialFurniture(kind:"sofa",point:PlanPoint(x:0.75,y:0.55),width:0.08,depth:0.25),SpatialFurniture(kind:"bed",point:PlanPoint(x:0.25,y:0.7),width:0.2,depth:0.2)]
        result.spatial = spatial
        result.devices = [id(10):PlanPoint(x:0.25,y:0.25),id(20):PlanPoint(x:0.65,y:0.3),id(30):PlanPoint(x:0.28,y:0.52),id(40):PlanPoint(x:0.65,y:0.75)]
        return result
    }
}
#endif
