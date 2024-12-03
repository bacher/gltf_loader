const std = @import("std");
const mem = std.mem;
const zstbi = @import("zstbi");

// TODO: maybe adding pub to be able to import types from package as well.
usingnamespace @import("./types.zig");
const t = @This();

const debug = false;

pub const GltfLoader = struct {
    arena: std.heap.ArenaAllocator,
    gpa_allocator: std.mem.Allocator,
    gltf_wrapper: *const GltfWrapper,
    mesh_primitive: *const t.Primitive,
    gltf_file_root: []const u8,

    pub fn init(gpa_allocator: std.mem.Allocator, file_path: []const u8) !GltfLoader {
        var arena = std.heap.ArenaAllocator.init(gpa_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const gltf_file_root = std.fs.path.dirname(file_path) orelse return error.DirNotFound;

        const file_handler = try std.fs.cwd().openFile(file_path, .{});

        const gltf_meta_json = try file_handler.readToEndAlloc(
            allocator,
            1_000_000,
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

        const mesh_index: t.MeshIndex = for (scene.nodes) |nodeIndex| {
            const node = gltf_wrapper.getNodeByIndex(nodeIndex);

            if (debug) {
                std.debug.print("NODE[{}] = \"{s}\" {any}\n", .{
                    nodeIndex,
                    node.name.?,
                    node,
                });
            }

            if (node.mesh) |mesh_index| {
                break mesh_index;
            }
        } else return error.NoMesh;

        const mesh = gltf_wrapper.getMeshByIndex(mesh_index);

        // Supports only GLTF files with one primitive per mesh.
        std.debug.assert(mesh.primitives.len == 1);

        return .{
            .arena = arena,
            .gpa_allocator = gpa_allocator,
            .gltf_wrapper = gltf_wrapper,
            .mesh_primitive = &mesh.primitives[0],
            .gltf_file_root = gltf_file_root,
        };
    }

    pub fn loadModelBuffers(self: *const GltfLoader, allocator: std.mem.Allocator) !ModelBuffers {
        // Supports only glTF files with one binary
        std.debug.assert(self.gltf_wrapper.gltf_root.buffers.len == 1);
        const binary_file_path = self.gltf_wrapper.gltf_root.buffers[0].uri;

        const indexes_accessor = self.gltf_wrapper.getAccessorByIndex(
            self.mesh_primitive.indices,
        );

        const positions_accessor = self.gltf_wrapper.getAccessorByIndex(
            self.mesh_primitive.attributes.POSITION,
        );

        const normals_accessor = self.gltf_wrapper.getAccessorByIndex(
            self.mesh_primitive.attributes.NORMAL,
        );

        const texcoord_accessor = self.gltf_wrapper.getAccessorByIndex(
            self.mesh_primitive.attributes.TEXCOORD_0,
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

        const indexes_buffer_u16 = std.mem.bytesAsSlice([3]u16, indexes_buffer);
        const positions_buffer_f32 = std.mem.bytesAsSlice([3]f32, positions_buffer);
        const normals_buffer_f32 = std.mem.bytesAsSlice([3]f32, normals_buffer);
        const texcoord_buffer_f32 = std.mem.bytesAsSlice([2]f32, texcoord_buffer);

        return .{
            .indexes = indexes_buffer_u16,
            .positions = positions_buffer_f32,
            .normals = normals_buffer_f32,
            .texcoord = texcoord_buffer_f32,
        };
    }

    fn loadBufferData(self: *const GltfLoader, file: std.fs.File, allocator: std.mem.Allocator, accessor: t.Accessor) ![]align(4) u8 {
        const buffer_view = self.gltf_wrapper.getBufferViewByIndex(accessor.bufferView);

        const result_buffer = try allocator.alignedAlloc(u8, 4, buffer_view.byteLength);

        try file.seekTo(buffer_view.byteOffset);
        const read_size = try file.read(result_buffer);
        std.debug.assert(read_size == result_buffer.len);

        return result_buffer;
    }

    pub fn loadTextureData(self: *const GltfLoader, file_path: []const u8) !zstbi.Image {
        const buffer_file_path = try std.fs.path.joinZ(self.gpa_allocator, &.{
            self.gltf_file_root,
            file_path,
        });
        defer self.gpa_allocator.free(buffer_file_path);

        return try zstbi.Image.loadFromFile(buffer_file_path, 4);
    }

    pub fn deinit(self: *const GltfLoader) void {
        self.arena.deinit();
    }
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
};

pub const ModelBuffers = struct {
    indexes: [][3]u16,
    positions: [][3]f32,
    normals: [][3]f32,
    texcoord: [][2]f32,

    pub fn deinit(self: *const ModelBuffers, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes);
        allocator.free(self.positions);
        allocator.free(self.normals);
        allocator.free(self.texcoord);
    }
};

test "GltfLoader can load model" {
    const test_allocator = std.testing.allocator;

    zstbi.init(test_allocator);
    defer zstbi.deinit();

    const loader = try GltfLoader.init(
        test_allocator,
        "assets/man/man.gltf.json",
    );
    defer loader.deinit();

    const buffers = try loader.loadModelBuffers(test_allocator);

    std.debug.print("indexes   buffer len = {}\n", .{buffers.indexes.len});
    std.debug.print("positions buffer len = {}\n", .{buffers.positions.len});
    std.debug.print("normals   buffer len = {}\n", .{buffers.normals.len});

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
        "assets/man/man.gltf.json",
    );
    defer loader.deinit();

    var image = try loader.loadTextureData("man.png");

    std.debug.print("texture: {d}x{d}\n", .{ image.width, image.height });

    image.deinit();
}
