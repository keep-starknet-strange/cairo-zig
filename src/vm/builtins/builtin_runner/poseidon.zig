const std = @import("std");
const relocatable = @import("../../memory/relocatable.zig");
const Felt252 = @import("../../../math/fields/starknet.zig").Felt252;
const poseidon_instance_def = @import("../../types/poseidon_instance_def.zig");
const Relocatable = @import("../../memory/relocatable.zig").Relocatable;
const MaybeRelocatable = @import("../../memory/relocatable.zig").MaybeRelocatable;
const Memory = @import("../../memory/memory.zig").Memory;
const MemorySegmentManager = @import("../../memory/segments.zig").MemorySegmentManager;

const AutoHashMap = std.AutoHashMap;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

/// Poseidon built-in runner
pub const PoseidonBuiltinRunner = struct {
    const Self = @This();

    /// Base
    base: usize = 0,
    /// Ratio
    ratio: ?u32,
    /// Number of cells per instance
    cells_per_instance: u32 = poseidon_instance_def.CELLS_PER_POSEIDON,
    /// Number of input cells
    n_input_cells: u32 = poseidon_instance_def.INPUT_CELLS_PER_POSEIDON,
    /// Stop pointer
    stop_ptr: ?usize = null,
    /// Included boolean flag
    included: bool,
    /// Cache
    ///
    /// Hashmap between an address in some memory segment and `Felt252` field element
    cache: AutoHashMap(Relocatable, Felt252),
    /// Number of instances per component
    instances_per_component: u32 = 1,

    /// Create a new PoseidonBuiltinRunner instance.
    ///
    /// This function initializes a new `PoseidonBuiltinRunner` instance with the provided
    /// `allocator`, `ratio`, and `included` values.
    ///
    /// # Arguments
    ///
    /// - `allocator`: An allocator for initializing the cache.
    /// - `ratio`: An optional 32-bit unsigned integer representing the ratio.
    /// - `included`: A boolean flag indicating whether this runner is included.
    ///
    /// # Returns
    ///
    /// A new `PoseidonBuiltinRunner` instance.
    pub fn init(
        allocator: Allocator,
        ratio: ?u32,
        included: bool,
    ) Self {
        return .{
            .ratio = ratio,
            .included = included,
            .cache = AutoHashMap(Relocatable, Felt252).init(allocator),
        };
    }

    pub fn initSegments(self: *Self, segments: *MemorySegmentManager) !void {
        _ = self;
        _ = segments;
    }

    pub fn initialStack(self: *Self, allocator: Allocator) !ArrayList(MaybeRelocatable) {
        _ = self;
        var result = ArrayList(MaybeRelocatable).init(allocator);
        errdefer result.deinit();
        return result;
    }

    pub fn deduceMemoryCell(
        self: *const Self,
        address: Relocatable,
        memory: *Memory,
    ) ?MaybeRelocatable {
        _ = memory;
        _ = address;
        _ = self;
        return null;
    }
};
