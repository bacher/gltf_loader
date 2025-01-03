const conststring = []const u8;

pub const GltfRoot = struct {
    asset: struct {
        version: f32,
    },
    scenes: []Scene,
    nodes: []Node,
    meshes: []Mesh,
    accessors: []Accessor,
    bufferViews: []BufferView,
    buffers: []Buffer,
};

pub const SceneIndex = enum(u32) { _ };

pub const Scene = struct {
    nodes: []NodeIndex,
};

pub const NodeIndex = enum(u32) { _ };

pub const Node = struct {
    name: ?conststring,
    children: ?[]NodeIndex = null,
    rotation: ?[4]f64 = null,
    scale: ?[3]f64 = null,
    translation: ?[3]f64 = null,
    mesh: ?MeshIndex = null,
    skin: ?u32 = null,
};

pub const MeshIndex = enum(u32) { _ };

pub const Mesh = struct {
    name: ?conststring = null,
    primitives: []Primitive,
};

pub const Primitive = struct {
    attributes: struct {
        POSITION: AccessorIndex,
        TEXCOORD_0: AccessorIndex,
        NORMAL: AccessorIndex,
        JOINTS_0: AccessorIndex,
        WEIGHTS_0: AccessorIndex,
    },
    indices: AccessorIndex,
    material: AccessorIndex,
};

const ComponentType = enum(u32) {
    // TODO?
    some1 = 5121,
    some2 = 5123,
    some3 = 5126,
};

pub const AccessorIndex = enum(u32) { _ };

pub const Accessor = struct {
    bufferView: BufferViewIndex,
    componentType: ComponentType,
    count: u32,
    min: ?[]f64 = null,
    max: ?[]f64 = null,
    type: []u8,
};

const TargetType = enum(u32) {
    // TODO?
    some1 = 34962, // regular buffer
    some2 = 34963, // index buffer
};

pub const BufferViewIndex = enum(u32) { _ };

pub const BufferView = struct {
    buffer: BufferIndex,
    byteOffset: u32,
    byteLength: u32,
    target: ?TargetType = null,
};

pub const BufferIndex = enum(u32) { _ };

pub const Buffer = struct {
    byteLength: u32,
    uri: []const u8,
};
