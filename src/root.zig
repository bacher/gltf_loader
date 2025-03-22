const std = @import("std");
const mem = std.mem;
const zstbi = @import("zstbi");
const expect = std.testing.expect;

// TODO: maybe adding pub to be able to import types from package as well.
// usingnamespace @import("./types.zig");
// const t = @This();
const t = @import("./types.zig");

const DEBUG = false;

pub const SceneObject = struct {
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

        return .{
            .transform_matrix = transform_matrix,
            .children = children,
            .mesh = mesh,
        };
    }

    fn findMeshNodeIndex(gltf_wrapper: *const GltfWrapper, node_indexes: []t.NodeIndex) ?t.MeshIndex {
        return for (node_indexes) |node_index| {
            const node = gltf_wrapper.getNodeByIndex(node_index);

            if (DEBUG) {
                std.debug.print("NODE[{}] = \"{s}\" {any}\n", .{
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

    fn findFirstObjectWithMeshNested(
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
                    return found;
                }
            }
        }

        return null;
    }

    pub fn loadModelBuffers(self: *const GltfLoader, allocator: std.mem.Allocator, mesh: *const Mesh) !ModelBuffers {
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

        const indexes_buffer = try self.loadBufferData(file, allocator, indexes_accessor);
        const positions_buffer = try self.loadBufferData(file, allocator, positions_accessor);
        const normals_buffer = try self.loadBufferData(file, allocator, normals_accessor);
        const texcoord_buffer = try self.loadBufferData(file, allocator, texcoord_accessor);

        const indexes_buffer_u16 = std.mem.bytesAsSlice([3]u16, indexes_buffer.slice);
        const positions_buffer_f32 = std.mem.bytesAsSlice([3]f32, positions_buffer.slice);
        const normals_buffer_f32 = std.mem.bytesAsSlice([3]f32, normals_buffer.slice);
        const texcoord_buffer_f32 = std.mem.bytesAsSlice([2]f32, texcoord_buffer.slice);

        return .{
            .indexes = .{
                .data = indexes_buffer_u16,
                .buffer = indexes_buffer.buffer,
            },
            .positions = .{
                .data = positions_buffer_f32,
                .buffer = positions_buffer.buffer,
            },
            .normals = .{
                .data = normals_buffer_f32,
                .buffer = normals_buffer.buffer,
            },
            .texcoord = .{
                .data = texcoord_buffer_f32,
                .buffer = texcoord_buffer.buffer,
            },
        };
    }

    fn loadBufferData(self: *const GltfLoader, file: std.fs.File, allocator: std.mem.Allocator, accessor: t.Accessor) !LoadedBuffer {
        const buffer_view = self.gltf_wrapper.getBufferViewByIndex(accessor.bufferView);

        const div4: u32 = @divFloor(buffer_view.byteLength, 4);
        var aligned_lenght = div4 * 4;
        if (aligned_lenght != buffer_view.byteLength) {
            aligned_lenght += 4;
        }

        const result_buffer = try allocator.alignedAlloc(u8, 4, aligned_lenght);

        try file.seekTo(buffer_view.byteOffset);
        const read_size = try file.read(result_buffer[0..buffer_view.byteLength]);
        std.debug.assert(read_size == buffer_view.byteLength);

        return .{
            .slice = result_buffer[0..buffer_view.byteLength],
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

pub fn ModelBuffer(comptime T: type) type {
    return struct {
        data: []T,
        buffer: []u8,
    };
}

pub const ModelBuffers = struct {
    indexes: ModelBuffer([3]u16),
    positions: ModelBuffer([3]f32),
    normals: ModelBuffer([3]f32),
    texcoord: ModelBuffer([2]f32),

    pub fn printDebugStats(self: *const ModelBuffers) void {
        std.debug.print("indexes   buffer len = {}\n", .{self.indexes.data.len});
        std.debug.print("positions buffer len = {}\n", .{self.positions.data.len});
        std.debug.print("normals   buffer len = {}\n", .{self.normals.data.len});
        std.debug.print("texcoord  buffer len = {}\n", .{self.texcoord.data.len});
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
