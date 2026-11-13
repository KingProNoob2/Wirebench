// Maraflow block definitions for Wirebench.
//
// Mirrors every statically registered definition of Maraflow's
// `cz.maramat.model.BlockCatalog` (the Bool, Math, I/O, Communication, Main.*,
// Macro, Visual and Ladder groups). `Macro.User.*` is registered dynamically by
// the Java catalog for each macro page and cannot be listed statically, so it is
// deliberately absent; the two static macro boundary blocks are included.
//
// GUIDs are deterministic UUID v5 values in the URL namespace, with the name
// "https://wirebench.local/maraflow/<definition id>". They were generated with:
//
//   python3 -c 'import uuid,sys;[print(str(uuid.uuid5(uuid.NAMESPACE_URL,
//       "https://wirebench.local/maraflow/" + d)).upper()) for d in sys.argv[1:]]' <ids...>
//
// i.e. exactly `uuid.uuid5(uuid.NAMESPACE_URL, "https://wirebench.local/maraflow/" + id)`.

import Foundation
import WirebenchCore

/// One Maraflow block pin (`BlockDefinition.PinSpec` in the Java catalog).
public struct MaraflowPinSpec: Sendable, Equatable {
    public let abbrev: String
    public let name: String
    public let dataType: String
    public let defaultValue: String
    /// True for the trailing variable operand of a variadic block.
    public let isCountedInput: Bool

    public init(abbrev: String, name: String, dataType: String,
                defaultValue: String, isCountedInput: Bool = false) {
        self.abbrev = abbrev
        self.name = name
        self.dataType = dataType
        self.defaultValue = defaultValue
        self.isCountedInput = isCountedInput
    }
}

/// One statically registered Maraflow block definition.
public struct MaraflowDefinition: Sendable, Equatable {
    public let id: String
    public let typeName: String
    public let category: String
    public let delphiClass: String
    public let summary: String
    public let inputs: [MaraflowPinSpec]
    public let outputs: [MaraflowPinSpec]
    public let variableInputCount: Bool
    public let configurableDataType: Bool
    public let defaultInputCount: Int?
    /// Deterministic UUID v5: URL namespace, name "https://wirebench.local/maraflow/" + id.
    public var guid: UUID

    public init(id: String, guid: UUID, typeName: String, category: String, delphiClass: String,
                summary: String, inputs: [MaraflowPinSpec], outputs: [MaraflowPinSpec],
                variableInputCount: Bool, configurableDataType: Bool, defaultInputCount: Int?) {
        self.id = id
        self.guid = guid
        self.typeName = typeName
        self.category = category
        self.delphiClass = delphiClass
        self.summary = summary
        self.inputs = inputs
        self.outputs = outputs
        self.variableInputCount = variableInputCount
        self.configurableDataType = configurableDataType
        self.defaultInputCount = defaultInputCount
    }
}

private func pin(_ abbrev: String, _ name: String, _ dataType: String,
                _ defaultValue: String) -> MaraflowPinSpec {
    MaraflowPinSpec(abbrev: abbrev, name: name, dataType: dataType, defaultValue: defaultValue)
}

private func makeDefinition(_ id: String, _ guid: String, _ typeName: String, _ category: String,
                            _ inputs: [MaraflowPinSpec], _ outputs: [MaraflowPinSpec],
                            variadic: Bool = false, configurable: Bool = false) -> MaraflowDefinition {
    MaraflowDefinition(
        id: id,
        guid: UUID(uuidString: guid)!,
        typeName: typeName,
        category: category,
        delphiClass: "TMMaraflow." + id,
        summary: typeName,
        inputs: inputs,
        outputs: outputs,
        variableInputCount: variadic,
        configurableDataType: configurable,
        defaultInputCount: variadic ? 2 : nil
    )
}

// Pins shared by several definitions.
private let enablePin = pin("En", "Enable Execution", "Boolean", "1")
private let noInputs: [MaraflowPinSpec] = []
private let noOutputs: [MaraflowPinSpec] = []
private let enableOnlyInputs: [MaraflowPinSpec] = [enablePin]
private let boolGateInputs: [MaraflowPinSpec] = [enablePin, pin("X1", "Input 1", "Boolean", "0"),
    pin("X2", "Input 2", "Boolean", "0")]
private let boolGateOutputs: [MaraflowPinSpec] = [pin("Y", "Logical Output", "Boolean", "0")]
private let mathMultiInputs: [MaraflowPinSpec] = [enablePin, pin("X1", "Operand 1", "Int", "0"),
    pin("X2", "Operand 2", "Int", "0")]
private let intResultOutputs: [MaraflowPinSpec] = [pin("Y", "Result", "Int", "0")]
private let intUnaryInputs: [MaraflowPinSpec] = [enablePin, pin("X", "Input Value", "Int", "0")]
private let floatUnaryInputs: [MaraflowPinSpec] = [enablePin, pin("X", "Input Value", "Float", "0")]
private let floatResultOutputs: [MaraflowPinSpec] = [pin("Y", "Result", "Float", "0")]
private let mathBinaryInputs: [MaraflowPinSpec] = [enablePin, pin("A", "Dividend / Base", "Int", "0"),
    pin("B", "Divisor / Exponent", "Int", "1")]
private let mathBinaryOutputs: [MaraflowPinSpec] = [pin("Y", "Result", "Int", "0"),
    pin("Err", "Division By Zero Error", "Boolean", "0")]
private let comparatorInputs: [MaraflowPinSpec] = [enablePin, pin("X1", "Left Operand", "Int", "0"),
    pin("X2", "Right Operand", "Int", "0")]
private let comparatorOutputs: [MaraflowPinSpec] = [pin("Y", "Comparison Result", "Boolean", "0")]
private let latchOutputs: [MaraflowPinSpec] = [pin("Q", "Latch Output", "Boolean", "0"),
    pin("nQ", "Inverted Latch Output", "Boolean", "1")]
private let contactOutputs: [MaraflowPinSpec] = [pin("Q", "Contact Output", "Boolean", "0")]
private let commWriteInputs: [MaraflowPinSpec] = [enablePin, pin("Val", "Value To Write", "Int", "0")]
private let commReadOutputs: [MaraflowPinSpec] = [pin("Val", "Register Value", "Int", "0"),
    pin("Ok", "Transaction OK", "Boolean", "0"), pin("Err", "Modbus Error Code", "Int", "0")]
private let commWriteOutputs: [MaraflowPinSpec] = [pin("Ok", "Transaction OK", "Boolean", "0"),
    pin("Err", "Modbus Error Code", "Int", "0")]
private let longTimestampOutputs: [MaraflowPinSpec] = [pin("Ts", "Unix Timestamp (s)", "Long", "0")]

/// The synthetic block that represents one Maraflow Structured Text page. It has no pins; the C++ core runs the
/// page's compiled ST each scan against the operand namespace.
public enum MaraflowStPage {
    public static let guid = UUID(uuidString: "DC5EE837-1FC3-5B44-B7A0-738FF999C929")!
    public static let info = BlockTypeInfo(guid: guid, blockName: "Maraflow ST page",
                                           delphiClass: "TMMaraflowST", category: "Reusable",
                                           summary: "Maraflow Structured Text page", isImplemented: false)
}

/// The synthetic block that represents one Maraflow ladder page (or one thread's rungs from it).
public enum MaraflowLdPage {
    public static let guid = UUID(uuidString: "FF2D353C-89E9-56F7-BD26-A9FA908811E5")!
    public static let info = BlockTypeInfo(guid: guid, blockName: "Maraflow LD page",
                                           delphiClass: "TMMaraflowLD", category: "Reusable",
                                           summary: "Maraflow ladder page", isImplemented: false)
}

/// Every statically registered Maraflow definition, keyed by its definition id.
public enum MaraflowCatalog {
    /// All statically registered definitions, in `BlockCatalog` registration order.
    public static let all: [MaraflowDefinition] = [
        makeDefinition("Bool.And", "5968820C-63B4-55F6-891A-113922A2F44D", "And", "Bool", boolGateInputs, boolGateOutputs, variadic: true),
        makeDefinition("Bool.Nand", "55C289D1-6610-5DFB-8BEC-B26CDF540585", "Nand", "Bool", boolGateInputs, boolGateOutputs, variadic: true),
        makeDefinition("Bool.Or", "738D2540-7E9D-52A5-8583-6ED7DBE59091", "Or", "Bool", boolGateInputs, boolGateOutputs, variadic: true),
        makeDefinition("Bool.Nor", "BD40D09C-52BD-5988-BEA3-CE7C2B11E5F5", "Nor", "Bool", boolGateInputs, boolGateOutputs, variadic: true),
        makeDefinition("Bool.Xor", "B5023904-A34F-5355-BA1B-E7BDA7E87BD8", "Xor", "Bool", boolGateInputs, boolGateOutputs, variadic: true),
        makeDefinition("Bool.Xnor", "EA0DC8CC-E68A-5E8F-8279-6A2EB4B87B80", "Xnor", "Bool", boolGateInputs, boolGateOutputs, variadic: true),
        makeDefinition("Bool.Not", "A682E3BE-C746-5C7F-973C-362650C58F80", "Not", "Bool", [pin("En", "Enable Execution", "Boolean", "1"), pin("X", "Input", "Boolean", "0")], [pin("Y", "Inverted Output", "Boolean", "0")]),
        makeDefinition("Bool.RS", "0B4FA97A-FCDD-5F03-BEE7-103871ECFFF6", "RS", "Bool", [pin("En", "Enable Execution", "Boolean", "1"), pin("S", "Set Input", "Boolean", "0"), pin("R", "Reset Input (Dominant)", "Boolean", "0")], latchOutputs),
        makeDefinition("Bool.SR", "586CAE22-197B-5DD5-84B7-D9B453CF5031", "SR", "Bool", [pin("En", "Enable Execution", "Boolean", "1"), pin("S", "Set Input (Dominant)", "Boolean", "0"), pin("R", "Reset Input", "Boolean", "0")], latchOutputs),
        makeDefinition("Math.Add", "DF3F123C-CAD9-5042-BBD0-0F263D61908B", "Add", "Math", mathMultiInputs, intResultOutputs, variadic: true, configurable: true),
        makeDefinition("Math.Sub", "9EC5AF63-46D5-51D7-B5C5-06992D82B0F7", "Sub", "Math", mathMultiInputs, intResultOutputs, variadic: true, configurable: true),
        makeDefinition("Math.Mul", "1DD27F0D-5E52-58C1-8A78-A2271753FC4E", "Mul", "Math", mathMultiInputs, intResultOutputs, variadic: true, configurable: true),
        makeDefinition("Math.Min", "1B547F52-C94A-50CD-B374-49364E350F73", "Min", "Math", mathMultiInputs, intResultOutputs, variadic: true, configurable: true),
        makeDefinition("Math.Max", "D4CD14EA-54F3-5E59-BC4E-CD061450A99C", "Max", "Math", mathMultiInputs, intResultOutputs, variadic: true, configurable: true),
        makeDefinition("Math.Div", "64748B89-1881-541E-B489-081DC2EC9C1C", "Div", "Math", mathBinaryInputs, mathBinaryOutputs, configurable: true),
        makeDefinition("Math.Mod", "7411DFE6-27BA-5DF7-BC2E-F408C64D125D", "Mod", "Math", mathBinaryInputs, mathBinaryOutputs, configurable: true),
        makeDefinition("Math.Pow", "0727674D-3FBC-523E-B3DD-0B05107695DB", "Pow", "Math", mathBinaryInputs, mathBinaryOutputs, configurable: true),
        makeDefinition("Math.Abs", "7FE0EDB4-B392-5F19-9C2A-18FE2A4C9CBA", "Abs", "Math", intUnaryInputs, intResultOutputs, configurable: true),
        makeDefinition("Math.Neg", "EDDFA78C-338D-533E-8662-852662AE1387", "Neg", "Math", intUnaryInputs, intResultOutputs, configurable: true),
        makeDefinition("Math.Sqrt", "448939CD-DA05-53B0-8EE1-8A043D31A864", "Sqrt", "Math", floatUnaryInputs, floatResultOutputs, configurable: true),
        makeDefinition("Math.Sin", "7E8A0937-3E4C-5EF6-B5FC-538488EE0306", "Sin", "Math", floatUnaryInputs, floatResultOutputs, configurable: true),
        makeDefinition("Math.Cos", "E0F7DFDC-644E-599A-B498-7CD4014A8D54", "Cos", "Math", floatUnaryInputs, floatResultOutputs, configurable: true),
        makeDefinition("Math.Clamp", "5FBC452E-CC8C-5FC2-88A0-D0CCEAD3A1DE", "Clamp", "Math", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Input Value", "Int", "0"), pin("Min", "Minimum Limit", "Int", "0"), pin("Max", "Maximum Limit", "Int", "100")], [pin("Y", "Clamped Output", "Int", "0")], configurable: true),
        makeDefinition("Math.Random", "532B910C-28F3-5AA2-AB98-9C94E8AD9E0E", "Random", "Math", [pin("En", "Enable Execution", "Boolean", "1"), pin("Trig", "Generate Trigger Edge", "Boolean", "1"), pin("Min", "Minimum Value", "Int", "0"), pin("Max", "Maximum Value", "Int", "100")], [pin("Y", "Random Value", "Int", "0")], configurable: true),
        makeDefinition("Math.Scale", "F56C9698-92A6-5F39-ACED-79DD6A550D31", "Scale", "Math", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Input Value", "Float", "0"), pin("Ilo", "Input Low", "Float", "0"), pin("Ihi", "Input High", "Float", "100"), pin("Olo", "Output Low", "Float", "0"), pin("Ohi", "Output High", "Float", "10")], [pin("Y", "Scaled Output", "Float", "0")], configurable: true),
        makeDefinition("Math.PID", "CECA7AEF-8489-5C26-8B7D-1A6B22B2ED44", "PID", "Math", [pin("En", "Enable Execution", "Boolean", "1"), pin("PV", "Process Variable", "Float", "0"), pin("SP", "Setpoint", "Float", "0"), pin("Kp", "Proportional Gain", "Float", "1"), pin("Ki", "Integral Gain", "Float", "0"), pin("Kd", "Derivative Gain", "Float", "0"), pin("Rst", "Reset Integrator", "Boolean", "0")], [pin("Out", "Controller Output", "Float", "0")]),
        makeDefinition("IO.DI", "790C64F1-2D2D-595B-8DFE-8691C9D1DEEF", "DI", "I/O", enableOnlyInputs, [pin("Y", "Digital Input State", "Boolean", "0")]),
        makeDefinition("IO.DO", "7EC54582-34C7-5480-97EA-6B7FDCF5495C", "DO", "I/O", [pin("En", "Enable Execution", "Boolean", "1"), pin("X", "Output Drive State", "Boolean", "0")], [pin("Y", "Confirmed Output State", "Boolean", "0")]),
        makeDefinition("IO.8xDI", "F9B0ABD2-12E0-539C-A128-8A5FCB3C492D", "8x DI", "I/O", enableOnlyInputs, [pin("DI0", "Digital Input 0", "Boolean", "0"), pin("DI1", "Digital Input 1", "Boolean", "0"), pin("DI2", "Digital Input 2", "Boolean", "0"), pin("DI3", "Digital Input 3", "Boolean", "0"), pin("DI4", "Digital Input 4", "Boolean", "0"), pin("DI5", "Digital Input 5", "Boolean", "0"), pin("DI6", "Digital Input 6", "Boolean", "0"), pin("DI7", "Digital Input 7", "Boolean", "0")]),
        makeDefinition("IO.8xDO", "9860B4B6-E1D8-53EF-9897-B7A64B4796AF", "8x DO", "I/O", [pin("En", "Enable Execution", "Boolean", "1"), pin("DO0", "Digital Output 0", "Boolean", "0"), pin("DO1", "Digital Output 1", "Boolean", "0"), pin("DO2", "Digital Output 2", "Boolean", "0"), pin("DO3", "Digital Output 3", "Boolean", "0"), pin("DO4", "Digital Output 4", "Boolean", "0"), pin("DO5", "Digital Output 5", "Boolean", "0"), pin("DO6", "Digital Output 6", "Boolean", "0"), pin("DO7", "Digital Output 7", "Boolean", "0")], [pin("Ok", "Port Write Status", "Boolean", "1")]),
        makeDefinition("IO.AI", "0E978790-C3C4-5A6B-8D86-613593292718", "AI", "I/O", enableOnlyInputs, [pin("Val", "Analog Input Raw/Scaled", "Int", "0")], configurable: true),
        makeDefinition("IO.AO", "3D1A47DA-58C0-567D-B912-DFCDE725CFD0", "AO", "I/O", [pin("En", "Enable Execution", "Boolean", "1"), pin("Val", "Analog Output Value", "Int", "0")], [pin("Ok", "DAC Status", "Boolean", "1")], configurable: true),
        makeDefinition("IO.PWM", "685C097D-E81D-5907-98B4-80247C11EF4B", "PWM", "I/O", [pin("En", "Enable Execution", "Boolean", "1"), pin("Frq", "Frequency (Hz)", "Int", "1000"), pin("Dty", "Duty Cycle (0-100%)", "Float", "50")], [pin("Act", "PWM Active", "Boolean", "0")]),
        makeDefinition("IO.Encoder", "9857F4AB-DE72-5AA5-9889-E99701B5E8F1", "Encoder", "I/O", [pin("En", "Enable Execution", "Boolean", "1"), pin("Rst", "Reset Counter", "Boolean", "0")], [pin("Cnt", "Quadrature Count", "Long", "0"), pin("Vel", "Pulse Velocity", "Int", "0")]),
        // Legacy Maraflow single-channel references, saved by older projects as `IO.IREF`/`IO.OREF` with a
        // `Channel` property ("DI0", "DO3", ...). They are the one-bit form of 8xDI/8xDO.
        makeDefinition("IO.IREF", "E2C49F39-7516-5508-AED3-70F1E3EABD9E", "IREF", "I/O", noInputs,
                       [pin("Y", "Input Reference", "Boolean", "0")]),
        makeDefinition("IO.OREF", "CBC0A94B-8EEB-5F8F-ACE0-E6155CBCEB7A", "OREF", "I/O",
                       [pin("X", "Output Reference", "Boolean", "0")], noOutputs),
        makeDefinition("Comm.ModbusRTU.MbRtuRead", "9F102FE4-BA5C-5E85-B31F-24E5A74013EB", "MbRtuRead", "Communication/Modbus RTU", enableOnlyInputs, commReadOutputs, configurable: true),
        makeDefinition("Comm.ModbusRTU.MbRtuWrite", "CCBA92D4-6DDB-5E6F-8C28-C240600EB1BE", "MbRtuWrite", "Communication/Modbus RTU", commWriteInputs, commWriteOutputs, configurable: true),
        makeDefinition("Comm.ModbusTCP.MbTcpRead", "7AB7CDEF-7323-589D-9E59-98DF3B418FD4", "MbTcpRead", "Communication/Modbus TCP", enableOnlyInputs, commReadOutputs, configurable: true),
        makeDefinition("Comm.ModbusTCP.MbTcpWrite", "7E365289-13A9-5C5B-B7DE-4FDD00B5D0F6", "MbTcpWrite", "Communication/Modbus TCP", commWriteInputs, commWriteOutputs, configurable: true),
        makeDefinition("Comm.REST.RestGet", "58302AF9-0C1C-51D0-A873-9CEB7EF71952", "RestGet", "Communication/REST", enableOnlyInputs, [pin("Out", "Parsed Response Value", "Float", "0"), pin("Sts", "HTTP Status Code", "Int", "200"), pin("Rdy", "Response Ready", "Boolean", "0")], configurable: true),
        makeDefinition("Comm.REST.RestPost", "00DC3C43-11B8-5ACB-919E-CD42937E031A", "RestPost", "Communication/REST", [pin("En", "Enable Execution", "Boolean", "1"), pin("Val", "Payload Value", "Float", "0")], [pin("Sts", "HTTP Status Code", "Int", "200"), pin("Rdy", "Request Completed", "Boolean", "0")], configurable: true),
        makeDefinition("Comm.DS18B20.DS18B20Read", "90993181-E168-524B-BB66-B4D5FB6A8F0D", "DS18B20", "Communication/DS18B20", enableOnlyInputs, [pin("Tmp", "Temperature (deg C)", "Float", "20"), pin("Ok", "Sensor CRC OK", "Boolean", "1")]),
        makeDefinition("Comm.I2C.I2CRead", "ABF331CE-6764-5979-98F9-E26364FB53C9", "I2CRead", "Communication/I2C", enableOnlyInputs, [pin("Val", "Read Value", "Int", "0"), pin("Ok", "I2C ACK OK", "Boolean", "1")], configurable: true),
        makeDefinition("Comm.I2C.I2CWrite", "2BF64BAF-DD2E-5082-9BD4-50A986AE402D", "I2CWrite", "Communication/I2C", [pin("En", "Enable Execution", "Boolean", "1"), pin("Val", "Byte/Word To Write", "Int", "0")], [pin("Ok", "I2C ACK OK", "Boolean", "1")], configurable: true),
        makeDefinition("Comm.SPI.SPITransfer", "D47C8EBC-5855-5144-B68D-DC2E108C10AA", "SPITransfer", "Communication/SPI", [pin("En", "Enable Execution", "Boolean", "1"), pin("Tx", "Transmit Word", "Int", "0")], [pin("Rx", "Received Word", "Int", "0"), pin("Ok", "Transfer Complete", "Boolean", "1")]),
        makeDefinition("Main.Arrays.ArrayRead", "3CD9941A-E675-525F-85AD-D6912F865F93", "ArrayRead", "Main/Arrays", [pin("En", "Enable Execution", "Boolean", "1"), pin("Idx", "Array Element Index", "Int", "0")], [pin("Val", "Element Value", "Int", "0"), pin("Oob", "Out Of Bounds", "Boolean", "0")], configurable: true),
        makeDefinition("Main.Arrays.ArrayWrite", "A336C829-6A39-5C68-971B-B795CF832A02", "ArrayWrite", "Main/Arrays", [pin("En", "Enable Execution", "Boolean", "1"), pin("Idx", "Array Element Index", "Int", "0"), pin("Val", "Element Value", "Int", "0")], [pin("Oob", "Out Of Bounds", "Boolean", "0")], configurable: true),
        makeDefinition("Main.Comparators.EQ", "113920DE-96F5-5B1C-818B-39BAFCB48B1B", "EQ", "Main/Comparators", comparatorInputs, comparatorOutputs, configurable: true),
        makeDefinition("Main.Comparators.NE", "881B42EE-F695-543C-B31D-81CFEB3CEFC8", "NE", "Main/Comparators", comparatorInputs, comparatorOutputs, configurable: true),
        makeDefinition("Main.Comparators.GT", "06276E25-01F5-57BA-95F0-B59D7AAADE55", "GT", "Main/Comparators", comparatorInputs, comparatorOutputs, configurable: true),
        makeDefinition("Main.Comparators.GE", "2E715074-5FAE-51A6-80F0-0A2DC70F9731", "GE", "Main/Comparators", comparatorInputs, comparatorOutputs, configurable: true),
        makeDefinition("Main.Comparators.LT", "4E951A10-D289-544A-A3A0-E6BE68326B56", "LT", "Main/Comparators", comparatorInputs, comparatorOutputs, configurable: true),
        makeDefinition("Main.Comparators.LE", "8078D43F-ECFB-5541-9C09-C5137D3415E5", "LE", "Main/Comparators", comparatorInputs, comparatorOutputs, configurable: true),
        makeDefinition("Main.Comparators.InRange", "DEB02650-C25C-5C63-BFD9-0B213BDCF688", "InRange", "Main/Comparators", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Input Value", "Int", "0"), pin("Min", "Lower Bound", "Int", "0"), pin("Max", "Upper Bound", "Int", "100")], [pin("Y", "Within Range", "Boolean", "0")], configurable: true),
        makeDefinition("Main.Comparators.Hysteresis", "D6523A22-49E0-5CEF-88F8-E5271C62D3CF", "Hysteresis", "Main/Comparators", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Input Signal", "Float", "0"), pin("Lo", "Low Threshold", "Float", "10"), pin("Hi", "High Threshold", "Float", "20")], [pin("Y", "Schmitt Trigger Output", "Boolean", "0")], configurable: true),
        makeDefinition("Main.Conversion.PackBits", "4AEA42BB-F7E2-5582-BD88-6D3814629C21", "PackBits", "Main/Conversion", [pin("En", "Enable Execution", "Boolean", "1"), pin("B0", "Bit 0", "Boolean", "0"), pin("B1", "Bit 1", "Boolean", "0"), pin("B2", "Bit 2", "Boolean", "0"), pin("B3", "Bit 3", "Boolean", "0"), pin("B4", "Bit 4", "Boolean", "0"), pin("B5", "Bit 5", "Boolean", "0"), pin("B6", "Bit 6", "Boolean", "0"), pin("B7", "Bit 7", "Boolean", "0")], [pin("Y", "Packed Integer", "Int", "0")]),
        makeDefinition("Main.Conversion.UnpackBits", "325F6C06-079D-5445-92C1-6CE02DA9E4A7", "UnpackBits", "Main/Conversion", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Packed Integer", "Int", "0")], [pin("B0", "Bit 0", "Boolean", "0"), pin("B1", "Bit 1", "Boolean", "0"), pin("B2", "Bit 2", "Boolean", "0"), pin("B3", "Bit 3", "Boolean", "0"), pin("B4", "Bit 4", "Boolean", "0"), pin("B5", "Bit 5", "Boolean", "0"), pin("B6", "Bit 6", "Boolean", "0"), pin("B7", "Bit 7", "Boolean", "0")]),
        makeDefinition("Main.Execution.ReadReg", "525838F7-F00A-5523-8C23-9A8D7C1D4678", "ReadReg", "Main/Execution", enableOnlyInputs, [pin("Out", "Register Value", "Int", "0")], configurable: true),
        makeDefinition("Main.Execution.WriteReg", "093B1AAB-CE33-51EF-BC54-DBE4CCBBA2BA", "WriteReg", "Main/Execution", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Value To Store", "Int", "0")], [pin("Out", "Stored Register Value", "Int", "0")], configurable: true),
        makeDefinition("Main.Execution.Interrupt", "A7B2E6D9-8531-5663-9615-7F403D61F690", "Interrupt", "Main/Execution", [pin("En", "Enable Execution", "Boolean", "1"), pin("Rst", "Reset Latched Flag (End of Scan)", "Boolean", "0")], [pin("Val", "Captured Event Value (GPIO / Pulse us / Count)", "Int", "0"), pin("Flg", "Interrupt Occurred Since Last Rst", "Boolean", "0")], configurable: true),
        makeDefinition("Main.Safety.EStop", "C4A215F7-CAF9-547E-90DE-349B63DE8719", "EStop", "Main/Safety", [pin("En", "Enable Execution", "Boolean", "1"), pin("Rst", "Manual Safety Reset (Rising Edge)", "Boolean", "0")], [pin("Safe", "Safety OK (1=Run, 0=Tripped)", "Boolean", "1"), pin("Trip", "E-Stop Tripped Active", "Boolean", "0"), pin("Src", "Tripped Channel Bitmask", "Int", "0")]),
        makeDefinition("Main.Filters.MovingAvg", "4A7443E9-2DC8-58E2-9EA8-037D9F053430", "MovingAvg", "Main/Filters", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Sample Input", "Float", "0"), pin("Rst", "Reset Window", "Boolean", "0")], [pin("Y", "Filtered Average", "Float", "0")]),
        makeDefinition("Main.Filters.LowPass", "0D585863-C9EF-58A9-B13F-EE19F13A445A", "LowPass", "Main/Filters", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Input Signal", "Float", "0"), pin("Alp", "Smoothing Factor Alpha (0..1)", "Float", "0.1")], [pin("Y", "Filtered Output", "Float", "0")]),
        makeDefinition("Main.Filters.Debounce", "CE0CED69-5949-5463-97D3-46C823C58697", "Debounce", "Main/Filters", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Raw Boolean Input", "Boolean", "0"), pin("Tms", "Debounce Time (ms)", "Int", "50")], [pin("Y", "Debounced Output", "Boolean", "0")]),
        makeDefinition("Main.Switches.Sel", "D8EBDAAF-FC4B-5379-B416-30090C4A1C3E", "Sel", "Main/Switches", [pin("En", "Enable Execution", "Boolean", "1"), pin("G", "Select Gate (0=X0, 1=X1)", "Boolean", "0"), pin("X0", "Input 0", "Int", "0"), pin("X1", "Input 1", "Int", "0")], [pin("Y", "Selected Output", "Int", "0")], configurable: true),
        makeDefinition("Main.Switches.Mux", "C281B9C9-7294-582B-8ACD-4B7740CB7357", "Mux", "Main/Switches", [pin("En", "Enable Execution", "Boolean", "1"), pin("Adr", "Input Address Index (0..N-1)", "Int", "0"), pin("X0", "Channel 0", "Int", "0"), pin("X1", "Channel 1", "Int", "0")], [pin("Y", "Multiplexed Output", "Int", "0")], variadic: true, configurable: true),
        makeDefinition("Main.Switches.Demux", "78DE4406-096D-54AE-B108-9AD728823749", "Demux", "Main/Switches", [pin("En", "Enable Execution", "Boolean", "1"), pin("Adr", "Output Address Index", "Int", "0"), pin("In", "Input Signal", "Int", "0")], [pin("Y0", "Output 0", "Int", "0"), pin("Y1", "Output 1", "Int", "0")], configurable: true),
        makeDefinition("Main.Timers.DateTime", "C2E37E66-40CD-50E4-8AA7-52CAB53A5949", "DateTime", "Main/Timers", enableOnlyInputs, longTimestampOutputs),
        makeDefinition("Main.Timers.DecodeDate", "098A0A82-9ED9-5FEC-AB04-37A68AE81B93", "DecodeDate", "Main/Timers", [pin("En", "Enable Execution", "Boolean", "1"), pin("Ts", "Unix Timestamp (s)", "Long", "0")], [pin("Yr", "Year", "Int", "1970"), pin("Mon", "Month (1-12)", "Int", "1"), pin("Day", "Day (1-31)", "Int", "1"), pin("Hr", "Hour (0-23)", "Int", "0"), pin("Min", "Minute (0-59)", "Int", "0"), pin("Sec", "Second (0-59)", "Int", "0")]),
        makeDefinition("Main.Timers.EncodeDate", "5C3AA1BF-3EC4-5643-BDD2-E23E242E4848", "EncodeDate", "Main/Timers", [pin("En", "Enable Execution", "Boolean", "1"), pin("Yr", "Year", "Int", "2026"), pin("Mon", "Month (1-12)", "Int", "1"), pin("Day", "Day (1-31)", "Int", "1"), pin("Hr", "Hour (0-23)", "Int", "0"), pin("Min", "Minute (0-59)", "Int", "0"), pin("Sec", "Second (0-59)", "Int", "0")], longTimestampOutputs),
        makeDefinition("Main.Timers.PulseGen", "E93D0300-7A52-558E-9509-EE3446E03DAE", "PulseGen", "Main/Timers", [pin("En", "Enable Execution", "Boolean", "1"), pin("THi", "High Duration (ms)", "Int", "500"), pin("TLo", "Low Duration (ms)", "Int", "500")], [pin("Q", "Pulse Output", "Boolean", "0")]),
        makeDefinition("Main.Timers.PulseLen", "0A07774F-20B1-5D91-802D-035F8C090370", "PulseLen", "Main/Timers", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Trigger Input", "Boolean", "0"), pin("Len", "Pulse Length (ms)", "Int", "1000")], [pin("Q", "Stretched Pulse", "Boolean", "0")]),
        makeDefinition("Main.Timers.SinglePulse", "A24014BB-A3CA-52C1-8B7C-EF143BB86F12", "SinglePulse", "Main/Timers", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Edge Trigger Input", "Boolean", "0")], [pin("Q", "Single-Cycle Pulse Output", "Boolean", "0")]),
        makeDefinition("Main.Timers.Timer", "2126B250-1BC9-5936-9886-F13585325173", "Timer", "Main/Timers", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Timer Start Input", "Boolean", "0"), pin("PT", "Preset Time (ms)", "Int", "1000")], [pin("Q", "Timer Output", "Boolean", "0"), pin("ET", "Elapsed Time (ms)", "Int", "0")]),
        makeDefinition("Main.Timers.Counter", "1A461DF4-7A7F-54F5-9BBD-F372BE71E546", "Counter", "Main/Timers", [pin("En", "Enable Execution", "Boolean", "1"), pin("CU", "Count Up Edge", "Boolean", "0"), pin("CD", "Count Down Edge", "Boolean", "0"), pin("R", "Reset", "Boolean", "0"), pin("PV", "Preset Value", "Int", "10")], [pin("Q", "Preset Reached", "Boolean", "0"), pin("CV", "Current Count Value", "Int", "0")]),
        makeDefinition("Macro.MacroIn", "19A2EF4A-3F7B-5B40-B5EE-1DF46C7BF9A1", "MacroIn", "Macro", noInputs, [pin("X1", "Macro Input 1", "Int", "0")]),
        makeDefinition("Macro.MacroOut", "A6715278-0DF1-5741-AE38-8A89112B9400", "MacroOut", "Macro", [pin("Y1", "Macro Output 1", "Int", "0")], noOutputs),
        makeDefinition("Visual.Segment", "E7C2B2D1-1234-5E88-8EF6-5291A331F60B", "Segment", "Visual", [pin("A", "Segment A (Top)", "Boolean", "0"), pin("B", "Segment B (Top-Right)", "Boolean", "0"), pin("C", "Segment C (Bottom-Right)", "Boolean", "0"), pin("D", "Segment D (Bottom)", "Boolean", "0"), pin("E", "Segment E (Bottom-Left)", "Boolean", "0"), pin("F", "Segment F (Top-Left)", "Boolean", "0"), pin("G", "Segment G (Middle)", "Boolean", "0"), pin("DP", "Decimal Point", "Boolean", "0")], noOutputs),
        makeDefinition("Visual.Value", "53B4415E-2DC6-5E9D-ADEF-6AA10DA9AF1E", "Value", "Visual", [pin("In", "Monitored Value", "Int", "0")], noOutputs, configurable: true),
        makeDefinition("Visual.Vars.BoolVar", "4C170954-23EC-5393-92AC-9DDD06F9A29C", "BoolVar", "Visual/Vars", noInputs, [pin("Y", "Injected Boolean Value", "Boolean", "0")]),
        makeDefinition("Visual.Vars.IntVar", "7FB21974-F4E1-58BE-8CA6-F38675C6D944", "IntVar", "Visual/Vars", noInputs, [pin("Y", "Injected 32-bit Integer Value", "Int", "0")]),
        makeDefinition("Visual.Vars.LongVar", "F0FE0BAB-6CD7-572D-BA04-F524F0457DAD", "LongVar", "Visual/Vars", noInputs, [pin("Y", "Injected 64-bit Long Value", "Long", "0")]),
        makeDefinition("Ladder.Contact.NO", "191E695A-BCD0-59BF-BDAA-98C96DB2F746", "NO Contact (--| |--)", "Ladder (LD)/Contacts", enableOnlyInputs, contactOutputs),
        makeDefinition("Ladder.Contact.NC", "B3F12E4A-4001-568E-809F-E6B08DCBA9FC", "NC Contact (--|/|--)", "Ladder (LD)/Contacts", enableOnlyInputs, contactOutputs),
        makeDefinition("Ladder.Contact.POS", "18655875-1557-5968-AE9E-141CADBFDC1A", "Rising Contact (--|P|--)", "Ladder (LD)/Contacts", enableOnlyInputs, contactOutputs),
        makeDefinition("Ladder.Contact.NEG", "6D9388BC-3791-5AF2-80C4-AE8CD9A65DB6", "Falling Contact (--|N|--)", "Ladder (LD)/Contacts", enableOnlyInputs, contactOutputs),
        makeDefinition("Ladder.Coil.NORMAL", "F37D5C86-EBF0-56DD-9038-689B76A6386F", "Normal Coil (--( )--)", "Ladder (LD)/Coils", enableOnlyInputs, noOutputs),
        makeDefinition("Ladder.Coil.NEGATED", "2B5176CB-CC4F-540C-B1E8-2FDA7170E085", "Negated Coil (--(/)--)", "Ladder (LD)/Coils", enableOnlyInputs, noOutputs),
        makeDefinition("Ladder.Coil.SET", "26546171-B573-53AA-82AA-AA856918E9E0", "Set Coil (--(S)--)", "Ladder (LD)/Coils", enableOnlyInputs, noOutputs),
        makeDefinition("Ladder.Coil.RESET", "54005D9F-6CB7-522D-90E1-DA6030CC136F", "Reset Coil (--(R)--)", "Ladder (LD)/Coils", enableOnlyInputs, noOutputs),
        makeDefinition("Ladder.Coil.POS", "680B0272-16D8-571E-8804-3BDB7206117C", "Rising Coil (--(P)--)", "Ladder (LD)/Coils", enableOnlyInputs, noOutputs),
        makeDefinition("Ladder.Coil.NEG", "40F82207-0029-5D0F-BB8F-42743FD0BC11", "Falling Coil (--(N)--)", "Ladder (LD)/Coils", enableOnlyInputs, noOutputs),
        makeDefinition("Ladder.Coil.WRITE_REG", "10C55DD9-05AC-561A-BFF2-72784E0590A5", "Write Register (--[REG :=]--)", "Ladder (LD)/Registers & Analog", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Register Value", "Int", "1")], noOutputs, configurable: true),
        makeDefinition("Ladder.Coil.ANALOG", "F6AA91AF-A0AC-5DE1-AFF4-80D30DC6D73E", "Analog Output / Move (--[AO :=]--)", "Ladder (LD)/Registers & Analog", [pin("En", "Enable Execution", "Boolean", "1"), pin("In", "Analog Source", "Int", "AI0")], noOutputs, configurable: true),
    ]

    /// Definitions whose runtime semantics the C++ core implements. Kept explicit so an unimplemented synthetic
    /// type is reported unported rather than silently holding its pins.
    public static let ported: Set<String> = [
        "Bool.And", "Bool.Nand", "Bool.Or", "Bool.Nor", "Bool.Xor", "Bool.Xnor", "Bool.Not",
        "Bool.RS", "Bool.SR",
        "Math.Add", "Math.Sub", "Math.Mul", "Math.Min", "Math.Max", "Math.Div", "Math.Mod",
        "Math.Pow", "Math.Abs", "Math.Neg", "Math.Sqrt", "Math.Sin", "Math.Cos", "Math.Clamp",
        "Math.Random", "Math.Scale", "Math.PID",
        "Main.Comparators.EQ", "Main.Comparators.NE", "Main.Comparators.GT", "Main.Comparators.GE",
        "Main.Comparators.LT", "Main.Comparators.LE", "Main.Comparators.InRange",
        "Main.Comparators.Hysteresis",
        "Main.Conversion.PackBits", "Main.Conversion.UnpackBits",
        "Main.Switches.Sel", "Main.Switches.Mux", "Main.Switches.Demux",
        "IO.DI", "IO.DO", "IO.8xDI", "IO.8xDO", "IO.AI", "IO.AO", "IO.PWM", "IO.Encoder",
        "IO.IREF", "IO.OREF",
        "Main.Timers.DateTime", "Main.Timers.DecodeDate", "Main.Timers.EncodeDate",
        "Main.Timers.PulseGen", "Main.Timers.PulseLen", "Main.Timers.SinglePulse",
        "Main.Timers.Timer", "Main.Timers.Counter",
        "Main.Filters.MovingAvg", "Main.Filters.LowPass", "Main.Filters.Debounce",
        "Main.Arrays.ArrayRead", "Main.Arrays.ArrayWrite",
        "Main.Safety.EStop",
        "Visual.Segment", "Visual.Value", "Visual.Vars.BoolVar", "Visual.Vars.IntVar",
        "Visual.Vars.LongVar",
        "Comm.ModbusRTU.MbRtuRead", "Comm.ModbusRTU.MbRtuWrite", "Comm.ModbusTCP.MbTcpRead",
        "Comm.ModbusTCP.MbTcpWrite", "Comm.REST.RestGet", "Comm.REST.RestPost",
        "Comm.DS18B20.DS18B20Read", "Comm.I2C.I2CRead", "Comm.I2C.I2CWrite",
        "Comm.SPI.SPITransfer",
        "Ladder.Contact.NO", "Ladder.Contact.NC", "Ladder.Contact.POS", "Ladder.Contact.NEG",
        "Ladder.Coil.NORMAL", "Ladder.Coil.NEGATED", "Ladder.Coil.SET", "Ladder.Coil.RESET",
        "Ladder.Coil.POS", "Ladder.Coil.NEG", "Ladder.Coil.WRITE_REG", "Ladder.Coil.ANALOG",
        "Main.Execution.ReadReg", "Main.Execution.WriteReg", "Main.Execution.Interrupt",
        "Macro.MacroIn", "Macro.MacroOut",
    ]

    /// All definitions keyed by definition id (e.g. `Bool.And`).
    public static let byId: [String: MaraflowDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static let byGuid: [UUID: MaraflowDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.guid, $0) })

    /// The definition with the given deterministic UUID v5, or `nil`.
    public static func definition(forGuid guid: UUID) -> MaraflowDefinition? {
        byGuid[guid]
    }

    /// The pin template of a definition, with its trailing variable operand marked as counted.
    public static func template(forGuid guid: UUID) -> BlockPinTemplate? {
        guard let block = definition(forGuid: guid) else { return nil }
        let outputs = block.outputs.map { spec in
            PinTemplate(abbrev: spec.abbrev, name: spec.name, dataType: spec.dataType,
                        defaultValue: spec.defaultValue)
        }
        if block.variableInputCount {
            // Keep the fixed prefix (`En`, or `En, Adr`) and replace the explicit operands with one counted
            // placeholder; `BlockFactory.makePins` then generates X1…Xn (or X0…Xn-1) without duplicating X1.
            let fixed = block.id == "Main.Switches.Mux" ? 2 : 1
            var inputs = block.inputs.prefix(fixed).map { spec in
                PinTemplate(abbrev: spec.abbrev, name: spec.name, dataType: spec.dataType,
                            defaultValue: spec.defaultValue)
            }
            let placeholder = block.inputs.indices.contains(fixed)
                ? block.inputs[fixed] : MaraflowPinSpec(abbrev: "X1", name: "Input", dataType: "Int", defaultValue: "0")
            inputs.append(PinTemplate(abbrev: placeholder.abbrev, name: placeholder.name,
                                      dataType: placeholder.dataType, defaultValue: placeholder.defaultValue,
                                      isCountedInput: true))
            return BlockPinTemplate(inputs: inputs, params: [], outputs: outputs,
                                    defaultInputCount: block.defaultInputCount)
        }
        let inputs = block.inputs.map { spec in
            PinTemplate(abbrev: spec.abbrev, name: spec.name, dataType: spec.dataType,
                        defaultValue: spec.defaultValue)
        }
        return BlockPinTemplate(inputs: inputs, params: [], outputs: outputs,
                                defaultInputCount: block.defaultInputCount)
    }

    /// Merge Maraflow's category paths into the Dirigo categories the palette already shows, so there is one
    /// Communication group instead of one per protocol and one Comparators/Timers/... group rather than duplicates
    /// whose display names only differ by a slash.
    static func paletteCategory(_ raw: String) -> String {
        if raw.hasPrefix("Communication/") { return "Communication" }
        if raw.hasPrefix("Ladder (LD)") { return "Ladder" }
        if raw == "Visual/Vars" { return "Vars" }
        if raw.hasPrefix("Main/") { return "Main\\" + raw.dropFirst("Main/".count) }
        return raw
    }

    /// `BlockTypeInfo` descriptors for the build palette and registry listings.
    public static let infos: [BlockTypeInfo] = all.map { block in
        BlockTypeInfo(guid: block.guid, blockName: block.typeName,
                      delphiClass: block.delphiClass, category: paletteCategory(block.category),
                      summary: "Maraflow · \(block.category)", isImplemented: false)
    }
}
