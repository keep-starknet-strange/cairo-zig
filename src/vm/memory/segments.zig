// Core imports.
const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

// Local imports.
const Memory = @import("memory.zig").Memory;
const relocatable = @import("relocatable.zig");
const Relocatable = @import("relocatable.zig").Relocatable;
const MaybeRelocatable = @import("relocatable.zig").MaybeRelocatable;
const Felt252 = @import("../../math/fields/starknet.zig").Felt252;

// MemorySegmentManager manages the list of memory segments.
// Also holds metadata useful for the relocation process of
// the memory at the end of the VM run.
pub const MemorySegmentManager = struct {
    const Self = @This();

    // ************************************************************
    // *                        FIELDS                            *
    // ************************************************************
    /// The allocator used to allocate the memory.
    allocator: Allocator,
    // The size of the used segments.
    segment_used_sizes: std.ArrayHashMap(
        u32,
        u32,
        std.array_hash_map.AutoContext(u32),
        false,
    ),
    // The size of the segments.
    segment_sizes: std.HashMap(
        u32,
        u32,
        std.hash_map.AutoContext(u32),
        std.hash_map.default_max_load_percentage,
    ),
    // The memory.
    memory: *Memory,
    // The public memory offsets.
    // TODO: Use correct type for this.
    public_memory_offsets: std.HashMap(
        u32,
        u32,
        std.hash_map.AutoContext(u32),
        std.hash_map.default_max_load_percentage,
    ),

    // ************************************************************
    // *             MEMORY ALLOCATION AND DEALLOCATION           *
    // ************************************************************

    // Creates a new MemorySegmentManager.
    // # Arguments
    // * `allocator` - The allocator to use for the HashMaps.
    // # Returns
    // A new MemorySegmentManager.
    pub fn init(allocator: Allocator) !*Self {
        // Create the pointer to the MemorySegmentManager.
        var segment_manager = try allocator.create(Self);
        errdefer allocator.destroy(segment_manager);

        const memory = try Memory.init(allocator);
        errdefer memory.deinit();

        // Initialize the values of the MemorySegmentManager struct.
        segment_manager.* = .{
            .allocator = allocator,
            .segment_used_sizes = std.AutoArrayHashMap(
                u32,
                u32,
            ).init(allocator),
            .segment_sizes = std.AutoHashMap(
                u32,
                u32,
            ).init(allocator),
            // Initialize the memory pointer.
            .memory = memory,
            .public_memory_offsets = std.AutoHashMap(u32, u32).init(allocator),
        };
        // Return the pointer to the MemorySegmentManager.
        return segment_manager;
    }

    // Safe deallocation of the memory.
    pub fn deinit(self: *Self) void {
        // Clear the hash maps
        self.segment_used_sizes.deinit();
        self.segment_sizes.deinit();
        self.public_memory_offsets.deinit();
        // Deallocate the memory.
        self.memory.deinit();
        // Deallocate self.
        self.allocator.destroy(self);
    }

    // ************************************************************
    // *                        METHODS                           *
    // ************************************************************

    // Adds a memory segment and returns the first address of the new segment.
    pub fn addSegment(self: *Self) Relocatable {
        // Create the relocatable address for the new segment.
        const relocatable_address = Relocatable{
            .segment_index = self.memory.num_segments,
            .offset = 0,
        };

        // Increment the number of segments.
        self.memory.num_segments += 1;

        return relocatable_address;
    }

    // Adds a temporary memory segment and returns the first address of the new segment.
    pub fn addTempSegment(self: *Self) Relocatable {
        // Increment the number of temporary segments.
        self.memory.num_temp_segments += 1;

        // Create the relocatable address for the new segment.
        const relocatable_address = Relocatable{
            .segment_index = -@as(i64, @intCast(self.memory.num_temp_segments)),
            .offset = 0,
        };

        return relocatable_address;
    }

    /// Retrieves the size of a memory segment by its index if available, else returns null.
    ///
    /// # Parameters
    /// - `index` (u32): The index of the memory segment.
    ///
    /// # Returns
    /// A `u32` representing the size of the segment or null if not computed.
    pub fn getSegmentUsedSize(self: *Self, index: u32) ?u32 {
        return self.segment_used_sizes.get(index) orelse null;
    }

    /// Retrieves the number of memory segments.
    ///
    /// # Returns
    ///
    /// The number of memory segments as a `usize`.
    pub fn numSegments(self: *Self) usize {
        return self.memory.data.count();
    }

    /// Retrieves the number of temporary memory segments.
    ///
    /// # Returns
    ///
    /// The number of temporary memory segments as a `usize`.
    pub fn numTempSegments(self: *Self) usize {
        return self.memory.temp_data.count();
    }

    /// Computes and returns the effective size of memory segments.
    ///
    /// This function iterates through memory segments, calculates their effective sizes, and
    /// updates the segment sizes map accordingly.
    ///
    /// # Returns
    ///
    /// An `AutoArrayHashMap` representing the computed effective sizes of memory segments.
    pub fn computeEffectiveSize(self: *Self) !std.AutoArrayHashMap(u32, u32) {
        for (self.memory.data.keys()) |item| {
            const offset = self.segment_used_sizes.get(@intCast(item.segment_index));
            if (offset == null or offset.? < item.offset + 1) {
                try self.segment_used_sizes.put(
                    @intCast(item.segment_index),
                    @intCast(item.offset + 1),
                );
            }
        }
        return self.segment_used_sizes;
    }

    /// Retrieves the size of a memory segment by its index if available, else computes it.
    ///
    /// This function attempts to retrieve the size of a memory segment by its index. If the size
    /// is not available in the segment sizes map, it calculates the effective size and returns it.
    ///
    /// # Parameters
    ///
    /// - `index` (u32): The index of the memory segment.
    ///
    /// # Returns
    ///
    /// A `u32` representing the size of the segment or a computed effective size if not available.
    pub fn getSegmentSize(self: *Self, index: u32) ?u32 {
        return self.segment_sizes.get(index) orelse self.getSegmentUsedSize(index);
    }

    /// Checks if a memory value is valid within the MemorySegmentManager.
    ///
    /// This function validates whether a given memory value is within the bounds
    /// of the memory segments managed by the MemorySegmentManager.
    ///
    /// # Parameters
    ///
    /// - `value` (*MaybeRelocatable): The memory value to validate.
    ///
    /// # Returns
    ///
    /// A boolean value indicating the validity of the memory value.
    pub fn isValidMemoryValue(self: *Self, value: *MaybeRelocatable) bool {
        return switch (value.*) {
            .felt => true,
            .relocatable => |item| @as(
                usize,
                @intCast(item.segment_index),
            ) < self.segment_used_sizes.count(),
        };
    }
};

// ************************************************************
// *                         TESTS                            *
// ************************************************************

test "memory segment manager" {
    // Initialize an allocator.
    var allocator = std.testing.allocator;

    // Initialize a memory segment manager.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    //Allocate a memory segment.
    const relocatable_address_1 = memory_segment_manager.addSegment();

    // Check that the memory segment manager has one segment.
    try expect(memory_segment_manager.memory.num_segments == 1);

    //Allocate a temporary memory segment.
    const relocatable_address_2 = memory_segment_manager.addTempSegment();

    try expect(memory_segment_manager.memory.num_temp_segments == 1);

    // Check if the relocatable address is correct.
    try expectEqual(
        Relocatable{
            .segment_index = 0,
            .offset = 0,
        },
        relocatable_address_1,
    );

    try expectEqual(
        Relocatable{
            .segment_index = -1,
            .offset = 0,
        },
        relocatable_address_2,
    );

    // Allocate another memory segment.
    const relocatable_address_3 = memory_segment_manager.addSegment();

    // Allocate another temporary memory segment.
    const relocatable_address_4 = memory_segment_manager.addTempSegment();

    // Check that the memory segment manager has two segments.
    try expect(memory_segment_manager.memory.num_segments == 2);
    // Check that the memory segment manager has two temporary segments.
    try expect(memory_segment_manager.memory.num_temp_segments == 2);

    // Check if the relocatable address is correct.
    try expectEqual(
        Relocatable{
            .segment_index = 1,
            .offset = 0,
        },
        relocatable_address_3,
    );
    try expectEqual(
        Relocatable{
            .segment_index = -2,
            .offset = 0,
        },
        relocatable_address_4,
    );
}

test "set get integer value in segment memory" {
    // ************************************************************
    // *                 SETUP TEST CONTEXT                       *
    // ************************************************************
    // Initialize an allocator.
    var allocator = std.testing.allocator;

    // Initialize a memory segment manager.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    // ************************************************************
    // *                      TEST BODY                           *
    // ************************************************************
    _ = memory_segment_manager.addSegment();
    _ = memory_segment_manager.addSegment();
    _ = memory_segment_manager.addTempSegment();
    _ = memory_segment_manager.addTempSegment();

    const address_1 = Relocatable.new(
        0,
        0,
    );
    const address_2 = Relocatable.new(
        -1,
        0,
    );
    const value_1 = relocatable.fromFelt(Felt252.fromInteger(42));

    const value_2 = relocatable.fromFelt(Felt252.fromInteger(84));

    const wrong_address = Relocatable.new(0, 1);

    _ = try memory_segment_manager.memory.set(address_1, value_1);
    _ = try memory_segment_manager.memory.set(address_2, value_2);

    try expect(memory_segment_manager.memory.data.contains(address_1));
    try expect(!memory_segment_manager.memory.data.contains(wrong_address));

    // ************************************************************
    // *                      TEST CHECKS                         *
    // ************************************************************
    const actual_value_1 = try memory_segment_manager.memory.get(address_1);
    const expected_value_1 = value_1;
    const actual_value_2 = try memory_segment_manager.memory.get(address_2);
    const expected_value_2 = value_2;

    try expect(expected_value_1.eq(actual_value_1));
    try expect(expected_value_2.eq(actual_value_2));
}

test "MemorySegmentManager: getSegmentUsedSize should return the size of a memory segment by its index if available" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(10, 4);
    try expectEqual(
        @as(u32, @intCast(4)),
        memory_segment_manager.getSegmentUsedSize(10).?,
    );
}

test "MemorySegmentManager: getSegmentUsedSize should return null if index not available" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try expectEqual(
        @as(?u32, null),
        memory_segment_manager.getSegmentUsedSize(10),
    );
}

test "MemorySegmentManager: numSegments should return the number of segments in the real memory" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 1), .{ .felt = Felt252.fromInteger(10) });
    try memory_segment_manager.memory.data.put(Relocatable.new(1, 1), .{ .felt = Felt252.fromInteger(10) });
    try expectEqual(
        @as(usize, 2),
        memory_segment_manager.numSegments(),
    );
}

test "MemorySegmentManager: numSegments should return the number of segments in the temporary memory" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.memory.temp_data.put(Relocatable.new(-1, 1), .{ .felt = Felt252.fromInteger(10) });
    try memory_segment_manager.memory.temp_data.put(Relocatable.new(-2, 1), .{ .felt = Felt252.fromInteger(10) });
    try expectEqual(
        @as(usize, 2),
        memory_segment_manager.numTempSegments(),
    );
}

test "MemorySegmentManager: computeEffectiveSize for one segment memory" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 0), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 1), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 2), .{ .felt = Felt252.fromInteger(1) });

    var actual = try memory_segment_manager.computeEffectiveSize();

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 3), actual.get(0).?);
}

test "MemorySegmentManager: computeEffectiveSize for one segment memory with gap" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    _ = memory_segment_manager.addSegment();
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 6), .{ .felt = Felt252.fromInteger(1) });

    var actual = try memory_segment_manager.computeEffectiveSize();

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 7), actual.get(0).?);
}

test "MemorySegmentManager: computeEffectiveSize for one segment memory with gaps" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 3), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 4), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 7), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 9), .{ .felt = Felt252.fromInteger(1) });

    var actual = try memory_segment_manager.computeEffectiveSize();

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 10), actual.get(0).?);
}

test "MemorySegmentManager: computeEffectiveSize for three segment memory" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 0), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 1), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 2), .{ .felt = Felt252.fromInteger(1) });

    try memory_segment_manager.memory.data.put(Relocatable.new(1, 0), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(1, 1), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(1, 2), .{ .felt = Felt252.fromInteger(1) });

    try memory_segment_manager.memory.data.put(Relocatable.new(2, 0), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(2, 1), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(2, 2), .{ .felt = Felt252.fromInteger(1) });

    var actual = try memory_segment_manager.computeEffectiveSize();

    try expectEqual(@as(usize, 3), actual.count());
    try expectEqual(@as(u32, 3), actual.get(0).?);
    try expectEqual(@as(u32, 3), actual.get(1).?);
    try expectEqual(@as(u32, 3), actual.get(2).?);
}

test "MemorySegmentManager: computeEffectiveSize for three segment memory with gaps" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 2), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 5), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 7), .{ .felt = Felt252.fromInteger(1) });

    try memory_segment_manager.memory.data.put(Relocatable.new(1, 1), .{ .felt = Felt252.fromInteger(1) });

    try memory_segment_manager.memory.data.put(Relocatable.new(2, 2), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(2, 4), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(2, 7), .{ .felt = Felt252.fromInteger(1) });

    var actual = try memory_segment_manager.computeEffectiveSize();

    try expectEqual(@as(usize, 3), actual.count());
    try expectEqual(@as(u32, 8), actual.get(0).?);
    try expectEqual(@as(u32, 2), actual.get(1).?);
    try expectEqual(@as(u32, 8), actual.get(2).?);
}

test "MemorySegmentManager: getSegmentUsedSize after computeEffectiveSize" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 2), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 5), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(0, 7), .{ .felt = Felt252.fromInteger(1) });

    try memory_segment_manager.memory.data.put(Relocatable.new(1, 1), .{ .felt = Felt252.fromInteger(1) });

    try memory_segment_manager.memory.data.put(Relocatable.new(2, 2), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(2, 4), .{ .felt = Felt252.fromInteger(1) });
    try memory_segment_manager.memory.data.put(Relocatable.new(2, 7), .{ .felt = Felt252.fromInteger(1) });

    _ = try memory_segment_manager.computeEffectiveSize();

    try expectEqual(@as(usize, 3), memory_segment_manager.segment_used_sizes.count());
    try expectEqual(@as(u32, 8), memory_segment_manager.segment_used_sizes.get(0).?);
    try expectEqual(@as(u32, 2), memory_segment_manager.segment_used_sizes.get(1).?);
    try expectEqual(@as(u32, 8), memory_segment_manager.segment_used_sizes.get(2).?);
}

test "MemorySegmentManager: getSegmentSize should return the size of the segment if contained in segment_sizes" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_sizes.put(10, 105);
    try expectEqual(@as(u32, 105), memory_segment_manager.getSegmentSize(10).?);
}

test "MemorySegmentManager: getSegmentSize should return the size of the segment via getSegmentUsedSize if not contained in segment_sizes" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(3, 6);
    try expectEqual(@as(u32, 6), memory_segment_manager.getSegmentSize(3).?);
}

test "MemorySegmentManager: getSegmentSize should return null if missing segment" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try expectEqual(@as(?u32, null), memory_segment_manager.getSegmentSize(3));
}

test "MemorySegmentManager: isValidMemoryValue should return true if Felt" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    var value: MaybeRelocatable = .{ .felt = Felt252.zero() };
    try expect(memory_segment_manager.isValidMemoryValue(&value));
}

test "MemorySegmentManager: isValidMemoryValue should return false if invalid segment" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(0, 10);
    var value: MaybeRelocatable = .{ .relocatable = Relocatable.new(1, 1) };
    try expect(!memory_segment_manager.isValidMemoryValue(&value));
}

test "MemorySegmentManager: isValidMemoryValue should return true if valid segment" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(0, 10);
    var value: MaybeRelocatable = .{ .relocatable = Relocatable.new(0, 5) };
    try expect(memory_segment_manager.isValidMemoryValue(&value));
}
