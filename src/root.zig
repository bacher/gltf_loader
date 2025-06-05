const std = @import("std");
const mem = std.mem;
const zstbi = @import("zstbi");
const expect = std.testing.expect;

// TODO: maybe adding pub to be able to import types from package as well.
// usingnamespace @import("./types.zig");
// const t = @This();
const t = @import("./types.zig");

const DEBUG = false;
const DEBUG_SHOW_NODE_NAMES = false;

pub const SceneObject = struct {
    name: ?[]const u8,
    transform_matrix: ?*const t.TransformMatrix,
    children: ?[]const SceneObject,
    mesh: ?*const Mesh,

    fn printDebugInfo(self: *const SceneObject) void {
        const children_number = children_number: {
            if (self.children) |children| {
                break :children_number children.len;
            } else {
                break :children_number 0;
            }
        };

        std.debug.print("debug: scene object. children={d:3}, matrix={:5}, mesh={?}\n", .{
            children_number,
            self.transform_matrix != null,
            self.mesh,
        });
    }
};

pub const Mesh = struct {
    name: ?[]const u8,
    mesh_primitive: *const t.Primitive,
    geometry_bounds: GeometryBounds,
};

pub const GltfLoader = struct {
    const LoadedBuffer = struct {
        buffer: []align(4) u8,
        slice: []align(4) u8,
    };

    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    gpa_allocator: std.mem.Allocator,
    gltf_wrapper: *const GltfWrapper,
    root: SceneObject,
    gltf_file_root: []const u8,

    pub fn init(gpa_allocator: std.mem.Allocator, file_path: []const u8) !GltfLoader {
        var arena = std.heap.ArenaAllocator.init(gpa_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const gltf_file_root = try allocator.dupe(
            u8,
            std.fs.path.dirname(file_path) orelse return error.DirNotFound,
        );

        const file_handler = try std.fs.cwd().openFile(file_path, .{});

        const gltf_meta_json = try file_handler.readToEndAlloc(
            allocator,
            100_000_000,
        );

        const gltf_meta_parsed = try std.json.parseFromSlice(
            t.GltfRoot,
            allocator,
            gltf_meta_json,
            .{
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .@"error",
            },
        );
        defer gltf_meta_parsed.deinit();

        const gltf_root = gltf_meta_parsed.value;

        const gltf_wrapper = try allocator.create(GltfWrapper);
        gltf_wrapper.gltf_root = gltf_root;

        const version = gltf_root.asset.version;
        std.debug.assert(version >= 2 and version < 3);

        // Supports only GLTF files with one scene.
        std.debug.assert(gltf_root.scenes.len == 1);
        const scene = gltf_root.scenes[0];

        var gltf_loader: GltfLoader = .{
            .arena = arena,
            .allocator = allocator,
            .gpa_allocator = gpa_allocator,
            .gltf_wrapper = gltf_wrapper,
            .root = undefined,
            .gltf_file_root = gltf_file_root,
        };

        gltf_loader.root = try gltf_loader.processSceneRoot(scene);

        return gltf_loader;
    }

    fn processSceneRoot(self: *const GltfLoader, scene: t.Scene) !SceneObject {
        const allocator = self.allocator;
        const gltf_wrapper = self.gltf_wrapper;

        const children = try allocator.alloc(SceneObject, scene.nodes.len);
        errdefer allocator.free(children);

        for (scene.nodes, 0..) |node_index, index| {
            const node = gltf_wrapper.getNodeByIndex(node_index);
            children[index] = try self.processSceneObject(node);
        }

        return .{
            .name = null,
            .transform_matrix = null,
            .children = children,
            .mesh = null,
        };
    }

    fn processSceneObject(self: *const GltfLoader, node: t.Node) !SceneObject {
        const allocator = self.allocator;
        const gltf_wrapper = self.gltf_wrapper;

        var transform_matrix: ?*const t.TransformMatrix = null;
        if (node.matrix) |matrix| {
            transform_matrix = matrix;
        }

        var mesh: ?*Mesh = null;
        if (node.mesh) |mesh_index| {
            const gltf_mesh = gltf_wrapper.getMeshByIndex(mesh_index);

            // Supports only GLTF files with one primitive per mesh.
            std.debug.assert(gltf_mesh.primitives.len == 1);

            const mesh_ptr = try allocator.create(Mesh);
            errdefer allocator.destroy(mesh_ptr);

            const geometry_bounds = try gltf_wrapper.getGeometryBounds(&gltf_mesh.primitives[0]);
            mesh_ptr.* = .{
                // .name = gltf_mesh.name,
                .name = null,
                .mesh_primitive = &gltf_mesh.primitives[0],
                .geometry_bounds = geometry_bounds,
            };

            mesh = mesh_ptr;
        }

        var children: ?[]const SceneObject = null;
        if (node.children) |node_children| {
            const children_ptr = try allocator.alloc(SceneObject, node_children.len);
            errdefer allocator.free(children_ptr);

            for (node_children, 0..) |child_node_index, index| {
                const child_node = gltf_wrapper.getNodeByIndex(child_node_index);
                children_ptr[index] = try self.processSceneObject(child_node);
            }
            children = children_ptr;
        }

        if (DEBUG_SHOW_NODE_NAMES) {
            if (node.name) |name| {
                std.debug.print("node name: {s}\n", .{name});
            }
        }

        return .{
            .name = node.name,
            .transform_matrix = transform_matrix,
            .children = children,
            .mesh = mesh,
        };
    }

    fn findMeshNodeIndex(gltf_wrapper: *const GltfWrapper, node_indexes: []t.NodeIndex) ?t.MeshIndex {
        return for (node_indexes) |node_index| {
            const node = gltf_wrapper.getNodeByIndex(node_index);

            if (DEBUG) {
                std.debug.print("NODE[{}] = '{s}' {any}\n", .{
                    node_index,
                    node.name.?,
                    node,
                });
            }

            if (node.mesh) |mesh_index| {
                break mesh_index;
            }

            if (node.children) |children| {
                if (findMeshNodeIndex(gltf_wrapper, children)) |mesh_node_index| {
                    break mesh_node_index;
                }
            }
        } else null;
    }

    pub fn findFirstObjectWithMesh(self: *const GltfLoader) ?*const SceneObject {
        return self.findFirstObjectWithMeshNested(&self.root);
    }

    pub fn findFirstObjectWithMeshNested(
        self: *const GltfLoader,
        object: *const SceneObject,
    ) ?*const SceneObject {
        if (object.mesh != null) {
            return object;
        }

        if (object.children) |children| {
            for (children) |*child| {
                const found = self.findFirstObjectWithMeshNested(child);
                if (found != null) {
                    return found.?;
                }
            }
        }

        return null;
    }

    pub fn getObjectByName(self: *const GltfLoader, name: []const u8) !*const SceneObject {
        return self.findObjectByNameNested(&self.root, name) orelse error.ObjectNotFound;
    }

    pub fn findObjectByNameNested(
        self: *const GltfLoader,
        object: *const SceneObject,
        name: []const u8,
    ) ?*const SceneObject {
        if (object.name) |object_name| {
            if (std.mem.eql(u8, object_name, name)) {
                return object;
            }
        }

        if (object.children) |children| {
            for (children) |*child| {
                const found_object = self.findObjectByNameNested(child, name);
                if (found_object != null) {
                    return found_object;
                }
            }
        }

        return null;
    }

    pub fn loadModelBuffers(
        self: *const GltfLoader,
        allocator: std.mem.Allocator,
        mesh: *const Mesh,
    ) !ModelBuffers {
        // Supports only glTF files with one binary
        std.debug.assert(self.gltf_wrapper.gltf_root.buffers.len == 1);
        const binary_file_path = self.gltf_wrapper.gltf_root.buffers[0].uri;

        const indexes_accessor = self.gltf_wrapper.getAccessorByIndex(
            mesh.mesh_primitive.indices,
        );

        const positions_accessor = self.gltf_wrapper.getAccessorByIndex(
            mesh.mesh_primitive.attributes.POSITION,
        );

        const normals_accessor = self.gltf_wrapper.getAccessorByIndex(
            mesh.mesh_primitive.attributes.NORMAL,
        );

        const texcoord_accessor = self.gltf_wrapper.getAccessorByIndex(
            mesh.mesh_primitive.attributes.TEXCOORD_0,
        );

        const buffer_file_path = try std.fs.path.join(self.gpa_allocator, &.{
            self.gltf_file_root,
            binary_file_path,
        });
        defer self.gpa_allocator.free(buffer_file_path);

        const file = try std.fs.cwd().openFile(buffer_file_path, .{});
        defer file.close();

        return .{
            .indexes = try self.loadModelBuffer(file, allocator, indexes_accessor),
            .positions = try self.loadModelBuffer(file, allocator, positions_accessor),
            .normals = try self.loadModelBuffer(file, allocator, normals_accessor),
            .texcoord = try self.loadModelBuffer(file, allocator, texcoord_accessor),
        };
    }

    fn loadModelBuffer(
        self: *const GltfLoader,
        file: std.fs.File,
        allocator: std.mem.Allocator,
        accessor: t.Accessor,
    ) !ModelBuffer {
        const buffer_view = self.gltf_wrapper.getBufferViewByIndex(accessor.bufferView);

        var element_type: ElementType = undefined;
        var component_byte_length: u32 = undefined;
        switch (accessor.componentType) {
            .gl_unsigned_byte => {
                component_byte_length = 1;
                element_type = .u8;
            },
            .gl_unsigned_short => {
                component_byte_length = 2;
                element_type = .u16;
            },
            .gl_unsigned_int => {
                component_byte_length = 4;
                element_type = .u32;
            },
            .gl_float => {
                component_byte_length = 4;
                element_type = .float;
            },
        }

        var component_number: u32 = undefined;
        if (std.mem.eql(u8, accessor.type, "SCALAR")) {
            component_number = 1;
        } else if (std.mem.eql(u8, accessor.type, "VEC2")) {
            component_number = 2;
        } else if (std.mem.eql(u8, accessor.type, "VEC3")) {
            component_number = 3;
        } else if (std.mem.eql(u8, accessor.type, "VEC4")) {
            component_number = 4;
        }

        const byte_offset = buffer_view.byteOffset + accessor.byteOffset;
        const byte_length = accessor.count * component_byte_length * component_number;

        // std.debug.print("offset={d:7} len={d:7} buffer_view_len={d:7}\n", .{ byte_offset, byte_length, buffer_view.byteLength });

        const div4: u32 = @divFloor(byte_length, 4);
        var aligned_length = div4 * 4;
        if (aligned_length != byte_length) {
            aligned_length += 4;
        }

        const result_buffer = try allocator.alignedAlloc(u8, 4, aligned_length);

        try file.seekTo(byte_offset);
        const read_size = try file.read(result_buffer[0..byte_length]);
        std.debug.assert(read_size == byte_length);

        return .{
            .type = element_type,
            .elements_count = accessor.count,
            .component_number = component_number,
            .byte_length = byte_length,
            .buffer = result_buffer,
        };
    }

    pub fn loadTextureData(self: *const GltfLoader, file_path: []const u8) !zstbi.Image {
        const buffer_file_path = try std.fs.path.joinZ(self.gpa_allocator, &.{
            self.gltf_file_root,
            file_path,
        });
        defer self.gpa_allocator.free(buffer_file_path);

        // std.debug.print("loading file: {s}\n", .{buffer_file_path});

        return try zstbi.Image.loadFromFile(buffer_file_path, 4);
    }

    pub fn deinit(self: *const GltfLoader) void {
        self.arena.deinit();
    }
};

pub const GeometryBounds = struct {
    min: [3]f64,
    max: [3]f64,
};

const GltfWrapper = struct {
    gltf_root: t.GltfRoot,

    fn getNodeByIndex(self: *const GltfWrapper, node_index: t.NodeIndex) t.Node {
        return self.gltf_root.nodes[@intFromEnum(node_index)];
    }

    fn getMeshByIndex(self: *const GltfWrapper, mesh_index: t.MeshIndex) t.Mesh {
        return self.gltf_root.meshes[@intFromEnum(mesh_index)];
    }

    fn getAccessorByIndex(self: *const GltfWrapper, accessor_index: t.AccessorIndex) t.Accessor {
        return self.gltf_root.accessors[@intFromEnum(accessor_index)];
    }

    fn getBufferViewByIndex(self: *const GltfWrapper, buffer_view_index: t.BufferViewIndex) t.BufferView {
        return self.gltf_root.bufferViews[@intFromEnum(buffer_view_index)];
    }

    fn getBufferByIndex(self: *const GltfWrapper, buffer_index: t.BufferIndex) t.Buffer {
        return self.gltf_root.buffers[@intFromEnum(buffer_index)];
    }

    fn getGeometryBounds(self: *const GltfWrapper, primitive: *t.Primitive) !GeometryBounds {
        const accessor = self.getAccessorByIndex(primitive.attributes.POSITION);

        if (accessor.min == null or accessor.max == null) {
            return error.NoGeometryBounds;
        }

        const min = accessor.min.?;
        const max = accessor.max.?;

        if (min.len < 3 or max.len < 3) {
            return error.InvalidGeometryBoundsFormat;
        }

        return .{
            .min = .{ min[0], min[1], min[2] },
            .max = .{ max[0], max[1], max[2] },
        };
    }
};

pub const ElementType = enum(u8) {
    u8 = 1,
    u16,
    u32,
    float,
};

pub const ModelBuffer = struct {
    type: ElementType,
    component_number: u32,
    elements_count: u32,
    byte_length: u32,
    buffer: []align(4) const u8,

    pub fn asTypedSlice(model_buffer: *const ModelBuffer, comptime SliceType: type) ![]const SliceType {
        const ElementElementType = std.meta.Elem(SliceType);

        if (!((ElementElementType == u8 and model_buffer.type == .u8) or (ElementElementType == u16 and model_buffer.type == .u16) or (ElementElementType == u16 and model_buffer.type == .u16) or (ElementElementType == f32 and model_buffer.type == .float))) {
            return error.TypeMismatch;
        }

        if (@typeInfo(SliceType).array.len != model_buffer.component_number) {
            return error.ArraySizeMismatch;
        }

        const slice: []align(4) const u8 = model_buffer.buffer[0..model_buffer.byte_length];

        return std.mem.bytesAsSlice(SliceType, slice);
    }
};

pub const ModelBuffers = struct {
    indexes: ModelBuffer,
    positions: ModelBuffer,
    normals: ModelBuffer,
    texcoord: ModelBuffer,

    pub fn printDebugStats(self: *const ModelBuffers) void {
        std.debug.print("indexes   buffer len = {}\n", .{self.indexes.elements_count});
        std.debug.print("positions buffer len = {}\n", .{self.positions.elements_count});
        std.debug.print("normals   buffer len = {}\n", .{self.normals.elements_count});
        std.debug.print("texcoord  buffer len = {}\n", .{self.texcoord.elements_count});
    }

    pub fn deinit(self: *const ModelBuffers, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes.buffer);
        allocator.free(self.positions.buffer);
        allocator.free(self.normals.buffer);
        allocator.free(self.texcoord.buffer);
    }
};

test "GltfLoader can load model" {
    const test_allocator = std.testing.allocator;

    zstbi.init(test_allocator);
    defer zstbi.deinit();

    const loader = try GltfLoader.init(
        test_allocator,
        "assets/man/man.gltf",
    );
    defer loader.deinit();

    const object = loader.findFirstObjectWithMesh();
    try expect(object != null);
    try expect(object.?.mesh != null);

    const buffers = try loader.loadModelBuffers(test_allocator, object.?.mesh.?);

    // buffers.printDebugStats();

    defer {
        buffers.deinit(test_allocator);
    }
}

test "GltfLoader can load scene" {
    const test_allocator = std.testing.allocator;

    zstbi.init(test_allocator);
    defer zstbi.deinit();

    const loader = try GltfLoader.init(
        test_allocator,
        "assets/toontown-central/scene.gltf",
    );
    defer loader.deinit();

    const object = loader.findFirstObjectWithMesh();
    try expect(object != null);
    try expect(object.?.mesh != null);

    const buffers = try loader.loadModelBuffers(test_allocator, object.?.mesh.?);

    // buffers.printDebugStats();

    defer {
        buffers.deinit(test_allocator);
    }
}

test "GltfLoader getObjectByName works" {
    const test_allocator = std.testing.allocator;

    zstbi.init(test_allocator);
    defer zstbi.deinit();

    const loader = try GltfLoader.init(
        test_allocator,
        "assets/toontown-central/scene.gltf",
    );
    defer loader.deinit();

    const object_4 = try loader.getObjectByName("Object_4");
    try expect(object_4.mesh != null);
}

test "GltfLoader can load model with odd number of triangles" {
    const test_allocator = std.testing.allocator;

    zstbi.init(test_allocator);
    defer zstbi.deinit();

    const loader = try GltfLoader.init(
        test_allocator,
        "assets/man-odd/man.gltf",
    );
    defer loader.deinit();

    const object = loader.findFirstObjectWithMesh();
    try expect(object != null);
    try expect(object.?.mesh != null);

    const buffers = try loader.loadModelBuffers(test_allocator, object.?.mesh.?);

    // buffers.printDebugStats();

    defer {
        buffers.deinit(test_allocator);
    }
}

test "GltfLoader can load model texture" {
    const test_allocator = std.testing.allocator;

    zstbi.init(test_allocator);
    defer zstbi.deinit();

    const loader = try GltfLoader.init(
        test_allocator,
        "assets/man/man.gltf",
    );
    defer loader.deinit();

    var image = try loader.loadTextureData("man.png");

    // std.debug.print("texture: {d}x{d}\n", .{ image.width, image.height });

    image.deinit();
}

test "GltfLoader can load scene with several objects" {
    const test_allocator = std.testing.allocator;

    zstbi.init(test_allocator);
    defer zstbi.deinit();

    const loader = try GltfLoader.init(
        test_allocator,
        "assets/toontown-central/scene.gltf",
    );
    defer loader.deinit();

    const root = loader.root;

    try expect(root.children.?.len == 1);
    try expect(root.children.?[0].children.?.len == 1);
    try expect(root.children.?[0].children.?[0].children.?.len == 1);
    try expect(root.children.?[0].children.?[0].children.?[0].children.?.len == 76);

    // root.children.?[0].printDebugInfo();
    // root.children.?[0].children.?[0].printDebugInfo();
    // root.children.?[0].children.?[0].children.?[0].printDebugInfo();
    // root.children.?[0].children.?[0].children.?[0].children.?[0].printDebugInfo();
    // root.children.?[0].children.?[0].children.?[0].children.?[0].children.?[0].printDebugInfo();
}

test "GltfLoader more complex flow" {
    const test_allocator = std.testing.allocator;

    zstbi.init(test_allocator);
    defer zstbi.deinit();

    const loader = try GltfLoader.init(
        test_allocator,
        "assets/toontown-central/scene.gltf",
    );
    defer loader.deinit();

    const gazebo = try loader.getObjectByName("ttc_gazebo_11");

    try expect(gazebo.children != null);
}

test "ModelBuffer asTypedSlice works" {
    const buffer: [3]f32 = .{ 0.1, 0.2, 0.3 };

    const underlying_bytes = std.mem.sliceAsBytes(&buffer);

    const model_buffer = ModelBuffer{
        .buffer = underlying_bytes,
        .type = .float,
        .elements_count = 3,
        .byte_length = @sizeOf(@TypeOf(buffer)),
        .component_number = 3,
    };

    const slice = try model_buffer.asTypedSlice([3]f32);

    try std.testing.expect(slice.len == 1);
    try std.testing.expect(slice[0][0] == 0.1);
    try std.testing.expect(slice[0][1] == 0.2);
    try std.testing.expect(slice[0][2] == 0.3);
}
