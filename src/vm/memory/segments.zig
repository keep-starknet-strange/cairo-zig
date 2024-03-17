// Core imports.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const Tuple = std.meta.Tuple;

// Local imports.
const Memory = @import("memory.zig").Memory;
const memoryFile = @import("memory.zig");
const MemoryCell = @import("memory.zig").MemoryCell;
const relocatable = @import("relocatable.zig");
const Relocatable = @import("relocatable.zig").Relocatable;
const MaybeRelocatable = @import("relocatable.zig").MaybeRelocatable;
const Felt252 = @import("../../math/fields/starknet.zig").Felt252;
const MemoryError = @import("../error.zig").MemoryError;
const MathError = @import("../error.zig").MathError;

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
        i64,
        u32,
        std.array_hash_map.AutoContext(i64),
        false,
    ),
    // The size of the segments.
    segment_sizes: std.AutoHashMap(u32, u32),
    // The memory.
    memory: *Memory,
    // The public memory offsets.
    // A map from segment index to a list of pairs (offset, page_id) that constitute the
    // public memory. Note that the offset is absolute (not based on the page_id).
    public_memory_offsets: std.AutoHashMap(
        usize,
        std.ArrayList(Tuple(&.{ usize, usize })),
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
        const segment_manager = try allocator.create(Self);
        errdefer allocator.destroy(segment_manager);

        const memory = try Memory.init(allocator);
        errdefer memory.deinit();

        // Initialize the values of the MemorySegmentManager struct.
        segment_manager.* = .{
            .allocator = allocator,
            .segment_used_sizes = std.AutoArrayHashMap(
                i64,
                u32,
            ).init(allocator),
            .segment_sizes = std.AutoHashMap(
                u32,
                u32,
            ).init(allocator),
            // Initialize the memory pointer.
            .memory = memory,
            .public_memory_offsets = std.AutoHashMap(
                usize,
                std.ArrayList(Tuple(&.{ usize, usize })),
            ).init(allocator),
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

    /// Adds a memory segment and returns the first address of the new segment.
    ///
    /// This function is responsible for adding a new memory segment to the
    /// MemorySegmentManager. It increments the number of segments and appends
    /// an uninitialized ArrayListUnmanaged to the memory data.
    ///
    /// # Returns
    /// Returns a Relocatable structure representing the first address of the new segment.
    pub fn addSegment(self: *Self) !Relocatable {
        // Create the relocatable address for the new segment.
        const relocatable_address = .{ .segment_index = self.memory.num_segments };

        // Increment the number of segments.
        self.memory.num_segments += 1;
        try self.memory.data.append(std.ArrayListUnmanaged(?MemoryCell){});

        return relocatable_address;
    }

    /// Adds a temporary memory segment and returns the first address of the new segment.
    ///
    /// This function is similar to `addSegment`, but it specifically adds a temporary
    /// memory segment. It increments the number of temporary segments and appends
    /// an uninitialized ArrayListUnmanaged to the temporary memory data.
    ///
    /// # Returns
    /// Returns a Relocatable structure representing the first address of the new temporary segment.
    pub fn addTempSegment(self: *Self) !Relocatable {
        // Increment the number of temporary segments.
        self.memory.num_temp_segments += 1;

        try self.memory.temp_data.append(std.ArrayListUnmanaged(?MemoryCell){});

        return .{ .segment_index = -@as(i64, @intCast(self.memory.num_temp_segments)) };
    }

    /// Retrieves the size of a memory segment by its index if available, else returns null.
    ///
    /// # Parameters
    /// - `index` (u32): The index of the memory segment.
    ///
    /// # Returns
    /// A `u32` representing the size of the segment or null if not computed.
    pub fn getSegmentUsedSize(self: *Self, index: u32) ?u32 {
        return self.segment_used_sizes.get(index);
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

    /// Retrieves the number of memory segments.
    ///
    /// # Returns
    ///
    /// The number of memory segments as a `usize`.
    pub fn numSegments(self: *Self) usize {
        return self.memory.data.items.len;
    }

    /// Retrieves the number of temporary memory segments.
    ///
    /// # Returns
    ///
    /// The number of temporary memory segments as a `usize`.
    pub fn numTempSegments(self: *Self) usize {
        return self.memory.temp_data.items.len;
    }

    /// Computes and returns the effective size of memory segments.
    ///
    /// This function iterates through memory segments, calculates their effective sizes, and
    /// updates the segment sizes map accordingly.
    ///
    /// # Returns
    ///
    /// An `AutoArrayHashMap` representing the computed effective sizes of memory segments.
    pub fn computeEffectiveSize(self: *Self, allow_tmp_segments: bool) !std.AutoArrayHashMap(i64, u32) {
        if (self.segment_used_sizes.count() != 0)
            return self.segment_used_sizes;

        // TODO: Check if memory is frozen. At the time of writting this function memory cannot be frozen so we cannot check if it frozen.

        for (self.memory.data.items, 0..) |segment, i| {
            try self.segment_used_sizes.put(
                @intCast(i),
                @intCast(segment.items.len),
            );
        }

        if (allow_tmp_segments) {
            for (self.memory.temp_data.items, 0..) |segment, i| {
                try self.segment_used_sizes.put(
                    -(@as(i64, @intCast(i)) + 1),
                    @intCast(segment.items.len),
                );
            }
        }
        return self.segment_used_sizes;
    }

    /// Computes the first relocated address of each memory segment
    ///
    ///  Relocation Logic:
    ///     Step 1: Get segment sizes:
    ///              0 --(has size)--> 3
    ///              1 --(has size)--> 5
    ///              2 --(has size)--> 1
    ///     Step 2: Assign a base to each segment:
    ///              0 --(has base value)--> 1
    ///              1 --(has base value)--> 4 (that is: 1 + 3)
    ///              2 --(has base value)--> 9 (that is: 4 + 5)
    /// # Returns
    ///
    /// A `Slice` of the `ArrayList(u32)` representing the relocated segments.
    pub fn relocateSegments(self: *Self, allocator: Allocator) !ArrayList(usize).Slice {
        const first_addr = 1;
        var relocatable_table = ArrayList(usize).init(allocator);
        errdefer relocatable_table.deinit();
        try relocatable_table.append(first_addr);
        for (self.segment_used_sizes.keys()) |key| {
            const index = self.segment_used_sizes.getIndex(key) orelse return MemoryError.MissingSegmentUsedSizes;
            const segment_size = self.getSegmentSize(@intCast(index)) orelse return MemoryError.MissingSegmentUsedSizes;
            try relocatable_table.append(relocatable_table.items[index] + segment_size);
        }
        // The last value corresponds to the total amount of elements across all segments, which isnt needed for relocation.
        _ = relocatable_table.pop();
        return relocatable_table.toOwnedSlice();
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

    // loadData loads data into the memory managed by MemorySegmentManager.
    //
    // This function iterates through the provided data in reverse order,
    // writing it into memory starting from the given `ptr` address.
    // It uses the allocator to set memory values and handles potential MemoryError.Math exceptions.
    //
    // # Parameters
    // - `allocator` (Allocator): The allocator for memory operations.
    // - `ptr` (Relocatable): The starting address in memory to write the data.
    // - `data` (*std.ArrayList(MaybeRelocatable)): The data to be loaded into memory.
    //
    // # Returns
    // A `Relocatable` representing the first address after the loaded data in memory.
    //
    // # Errors
    // - Returns a MemoryError.Math if there's an issue with memory arithmetic during loading.
    pub fn loadData(
        self: *Self,
        allocator: Allocator,
        ptr: Relocatable,
        data: []const MaybeRelocatable,
    ) !Relocatable {
        for (data, 0..) |d, i| {
            try self.memory.set(allocator, try (ptr.addUint(i) catch MemoryError.Math), d);
        }

        return ptr.addUint(data.len) catch MemoryError.Math;
    }

    /// Records details for a specified segment, facilitating relocation:
    /// - `segment_index`: The index of the segment to finalize.
    /// - `size`: The size of the segment for `relocate_segments`.
    /// - `public_memory`: A list of offsets for memory cells considered public memory.
    ///
    /// If a size is provided, it's set for relocation. If `public_memory` is not supplied,
    /// a default list is generated internally.
    ///
    /// Returns `MathError.ValueTooLarge` if the size exceeds the maximum supported value.
    pub fn finalize(
        self: *Self,
        segment_index: usize,
        size: ?usize,
        public_memory: ?std.ArrayList(Tuple(&.{ usize, usize })),
    ) !void {
        if (size) |s| {
            if (s > std.math.maxInt(u32)) return MathError.ValueTooLarge;
            try self.segment_sizes.put(
                @intCast(segment_index),
                @intCast(s),
            );
        }
        try self.public_memory_offsets.put(
            segment_index,
            if (public_memory) |p|
                p
            else blk: {
                var default = std.ArrayList(Tuple(&.{ usize, usize })).init(self.allocator);
                defer default.deinit();
                break :blk default;
            },
        );
    }

    /// Retrieves addresses of memory cells in the public memory based on segment offsets.
    ///
    /// Retrieves a list of addresses constituting the public memory using `segment_offsets`
    /// (resulting from `self.relocate_segments()`). If `self.relocate_segments()` is not yet
    /// implemented, this function returns an empty list.
    ///
    /// Returns a list of memory cell addresses that comprise the public memory.
    /// Throws `MemoryError.MalformedPublicMemory` if `segment_offsets` are incomplete.
    pub fn getPublicMemoryAddresses(
        self: *Self,
        segment_offsets: *const std.ArrayList(usize),
    ) !std.ArrayList(Tuple(&.{ usize, usize })) {
        // Initialize a list to store the resulting public memory addresses
        var public_memory_addresses = std.ArrayList(Tuple(&.{ usize, usize })).init(self.allocator);
        // Ensure that the list has enough capacity to accommodate the addresses
        try public_memory_addresses.ensureTotalCapacity(self.numSegments());
        // Defer deallocation of the list to handle potential errors
        errdefer public_memory_addresses.deinit();

        // Check if the provided segment offsets are incomplete
        if (segment_offsets.items.len < self.numSegments()) return MemoryError.MalformedPublicMemory;

        // Iterate through each segment to compute memory addresses
        for (0..self.numSegments()) |segment_index| {
            // Retrieve the starting offset of the current segment
            const segment_start = segment_offsets.items[segment_index];
            // Check if public memory offsets are available for the current segment
            if (self.public_memory_offsets.get(segment_index)) |pm| {
                // Iterate through public memory offsets for the current segment
                for (pm.items) |offset_tuple| {
                    // Calculate the absolute memory address by adding the offset to the segment start
                    try public_memory_addresses.append(.{
                        segment_start + offset_tuple[0],
                        offset_tuple[1],
                    });
                }
            }
        }
        // Return the list of public memory addresses
        return public_memory_addresses;
    }

    /// Writes data into the managed memory at the specified pointer location.
    ///
    /// This function writes data into the managed memory at the specified pointer location.
    /// It supports writing different types of data and handles the loading process into memory.
    ///
    /// # Parameters
    ///
    /// - `self`: A pointer to the MemorySegmentManager.
    /// - `T`: The type of data being written.
    /// - `ptr`: The starting address in memory to write the data.
    /// - `arg`: A pointer to the data to be loaded into memory.
    ///
    /// # Returns
    ///
    /// A `MaybeRelocatable` representing the first address after the loaded data in memory.
    /// If the type isn't supported, it returns `MemoryError.WriteArg`.
    ///
    /// # Errors
    ///
    /// Throws a `MemoryError.WriteArg` if unsupported data type is passed.
    pub fn writeArg(self: *Self, comptime T: type, ptr: Relocatable, arg: *T) !MaybeRelocatable {
        return switch (T) {
            std.ArrayList(MaybeRelocatable) => MaybeRelocatable.fromRelocatable(
                try self.loadData(
                    self.allocator,
                    ptr,
                    arg.items,
                ),
            ),
            std.ArrayList(Felt252) => {
                var tmp = std.ArrayList(MaybeRelocatable).init(self.allocator);
                defer tmp.deinit();

                for (arg.*.items) |r| try tmp.append(MaybeRelocatable.fromFelt(r));

                return self.writeArg(std.ArrayList(MaybeRelocatable), ptr, &tmp);
            },
            std.ArrayList(Relocatable) => {
                // Prepare to load Relocatable data into memory
                var tmp = std.ArrayList(MaybeRelocatable).init(self.allocator);
                defer tmp.deinit();
                // Iterate through each Relocatable item and prepare for loading
                for (arg.*.items) |r| {
                    try tmp.append(MaybeRelocatable.fromRelocatable(r));
                }
                // Load prepared data into memory and return the resulting address
                return MaybeRelocatable.fromRelocatable(
                    try self.loadData(
                        self.allocator,
                        ptr,
                        tmp.items,
                    ),
                );
            },
            else => MemoryError.WriteArg,
        };
    }

    /// Calculates the total memory holes in segments excluding built-in segments.
    /// Memory holes are computed by subtracting accessed addresses from segment sizes.
    ///
    /// Parameters:
    /// - `self`: Pointer to the structure containing memory information.
    /// - `builtin_count`: Number of built-in segments.
    /// - `has_output_builtin`: Boolean flag indication the presence of output builtin.
    ///
    /// Returns:
    /// Result containing the total memory holes or an error of type `MemoryError`.
    pub fn getMemoryHoles(
        self: *Self,
        builtin_count: usize,
        has_output_builtin: bool,
    ) MemoryError!usize {
        // Initialize variable to store the total memory holes
        var memory_holes: usize = 0;

        // Calculate the start and end indices for built-in segments
        const builtin_segments_start: usize = if (has_output_builtin) 2 else 1;
        const builtin_segments_end = builtin_segments_start + builtin_count;

        // Iterate through each segment in the memory data
        for (0..self.memory.data.items.len) |i| {
            // Skip built-in segments when counting memory holes
            if (i > builtin_segments_start and i <= builtin_segments_end) continue;

            // Get the amount of accessed addresses in the segment
            const accessed_amount = self.memory.countAccessedAddressesInSegment(@intCast(i)) orelse continue;
            // If no accessed addresses, move to the next segment
            if (accessed_amount == 0) continue;

            // Get the size of the segment
            const segment_size = self.getSegmentSize(@intCast(i)) orelse {
                return MemoryError.MissingSegmentUsedSizes;
            };

            // Check for more accessed addresses than the segment size
            if (accessed_amount > segment_size) return MemoryError.SegmentHasMoreAccessedAddressesThanSize;

            // Calculate and accumulate memory holes
            memory_holes += segment_size - accessed_amount;
        }

        // Return the total memory holes calculated
        return memory_holes;
    }

    /// Generates a relocatable argument for the managed memory.
    ///
    /// This function supports generating relocatable arguments for various data types. It provides
    /// flexibility in handling memory segments and writes the specified data into the managed memory.
    ///
    /// # Parameters
    ///
    /// - `self`: A pointer to the MemorySegmentManager.
    /// - `T`: The type of data for which the argument needs to be generated.
    /// - `arg`: A pointer to the data to be loaded into memory.
    ///
    /// # Returns
    ///
    /// A `MaybeRelocatable` representing the first address after the loaded data in memory.
    /// If the specified data type is not supported, it returns `MemoryError.GenArgInvalidType`.
    ///
    /// # Errors
    ///
    /// Throws a `MemoryError.GenArgInvalidType` if an unsupported data type is passed.
    pub fn genArg(self: *Self, comptime T: type, arg: *T) !MaybeRelocatable {
        return switch (T) {
            MaybeRelocatable => arg.*,
            std.ArrayList(MaybeRelocatable), std.ArrayList(Relocatable) => blk: {
                const base = try self.addSegment();
                _ = try self.writeArg(T, base, arg);
                break :blk MaybeRelocatable.fromRelocatable(base);
            },
            else => MemoryError.GenArgInvalidType,
        };
    }
};

// Utility function to help set up memory segments
//
// # Arguments
// - `segment_manager` - MemorySegmentManger to be passed in
// - `vals` - complile time structure with heterogenous types
pub fn segmentsUtil(segment_manager: *MemorySegmentManager, allocator: Allocator, comptime vals: anytype) !void {
    try segment_manager.memory.setUpMemory(allocator, vals);
}

// ************************************************************
// *                         TESTS                            *
// ************************************************************

test "memory segment manager" {
    // Initialize an allocator.
    const allocator = std.testing.allocator;

    // Initialize a memory segment manager.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    //Allocate a memory segment.
    const relocatable_address_1 = try memory_segment_manager.addSegment();

    // Check that the memory segment manager has one segment.
    try expect(memory_segment_manager.memory.num_segments == 1);

    //Allocate a temporary memory segment.
    const relocatable_address_2 = try memory_segment_manager.addTempSegment();

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
    const relocatable_address_3 = try memory_segment_manager.addSegment();

    // Allocate another temporary memory segment.
    const relocatable_address_4 = try memory_segment_manager.addTempSegment();

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
    const allocator = std.testing.allocator;

    // Initialize a memory segment manager.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    // ************************************************************
    // *                      TEST BODY                           *
    // ************************************************************

    const address_1 = Relocatable.init(
        0,
        0,
    );
    const address_2 = Relocatable.init(
        -1,
        0,
    );
    const value_1 = MaybeRelocatable.fromFelt(Felt252.fromInt(u8, 42));

    const value_2 = MaybeRelocatable.fromFelt(Felt252.fromInt(u8, 84));

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{42} },
            .{ .{ -1, 0 }, .{84} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    // ************************************************************
    // *                      TEST CHECKS                         *
    // ************************************************************
    const actual_value_1 = memory_segment_manager.memory.get(address_1);
    const expected_value_1 = value_1;
    const actual_value_2 = memory_segment_manager.memory.get(address_2);
    const expected_value_2 = value_2;

    try expect(expected_value_1.eq(actual_value_1.?));
    try expect(expected_value_2.eq(actual_value_2.?));
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

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 1 }, .{10} },
            .{ .{ 1, 1 }, .{10} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    try expectEqual(
        @as(usize, 2),
        memory_segment_manager.numSegments(),
    );
}

test "MemorySegmentManager: numSegments should return the number of segments in the temporary memory" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ -1, 1 }, .{10} },
            .{ .{ -2, 1 }, .{10} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    try expectEqual(
        @as(usize, 2),
        memory_segment_manager.numTempSegments(),
    );
}

test "MemorySegmentManager: computeEffectiveSize for one segment memory" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{1} },
            .{ .{ 0, 1 }, .{1} },
            .{ .{ 0, 2 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(false);

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 3), actual.get(0).?);
}

test "MemorySegmentManager: computeEffectiveSize for one segment memory with gap" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 0, 6 }, .{1} }},
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(false);

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 7), actual.get(0).?);
}

test "MemorySegmentManager: computeEffectiveSize for one segment memory with gaps" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 3 }, .{1} },
            .{ .{ 0, 4 }, .{1} },
            .{ .{ 0, 7 }, .{1} },
            .{ .{ 0, 9 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(false);

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 10), actual.get(0).?);
}

test "MemorySegmentManager: computeEffectiveSize for three segment memory" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{1} },
            .{ .{ 0, 1 }, .{1} },
            .{ .{ 0, 2 }, .{1} },
            .{ .{ 1, 0 }, .{1} },
            .{ .{ 1, 1 }, .{1} },
            .{ .{ 1, 2 }, .{1} },
            .{ .{ 2, 0 }, .{1} },
            .{ .{ 2, 1 }, .{1} },
            .{ .{ 2, 2 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(false);

    try expectEqual(@as(usize, 3), actual.count());
    try expectEqual(@as(u32, 3), actual.get(0).?);
    try expectEqual(@as(u32, 3), actual.get(1).?);
    try expectEqual(@as(u32, 3), actual.get(2).?);
}

test "MemorySegmentManager: computeEffectiveSize for three segment memory with gaps" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 2 }, .{1} },
            .{ .{ 0, 5 }, .{1} },
            .{ .{ 0, 7 }, .{1} },

            .{ .{ 1, 1 }, .{1} },

            .{ .{ 2, 2 }, .{1} },
            .{ .{ 2, 4 }, .{1} },
            .{ .{ 2, 7 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(false);

    try expectEqual(@as(usize, 3), actual.count());
    try expectEqual(@as(u32, 8), actual.get(0).?);
    try expectEqual(@as(u32, 2), actual.get(1).?);
    try expectEqual(@as(u32, 8), actual.get(2).?);
}

test "MemorySegmentManager: computeEffectiveSize (with temp segments) for one segment memory" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ -1, 0 }, .{1} },
            .{ .{ -1, 1 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(true);

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 2), actual.get(-1).?);
}

test "MemorySegmentManager: computeEffectiveSize (with temp segments) for one segment memory with gap" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    _ = try memory_segment_manager.addTempSegment();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ -1, 6 }, .{1} }},
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(true);

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 7), actual.get(-1).?);
}

test "MemorySegmentManager: computeEffectiveSize (with temp segments) for one segment memory with gaps" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ -1, 3 }, .{1} },
            .{ .{ -1, 4 }, .{1} },
            .{ .{ -1, 7 }, .{1} },
            .{ .{ -1, 9 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(true);

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 10), actual.get(-1).?);
}

test "MemorySegmentManager: computeEffectiveSize (with temp segments) for three segment memory" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ -3, 0 }, .{1} },
            .{ .{ -3, 1 }, .{1} },
            .{ .{ -3, 2 }, .{1} },

            .{ .{ -2, 0 }, .{1} },
            .{ .{ -2, 1 }, .{1} },
            .{ .{ -2, 2 }, .{1} },

            .{ .{ -1, 0 }, .{1} },
            .{ .{ -1, 1 }, .{1} },
            .{ .{ -1, 2 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(true);

    try expectEqual(@as(usize, 3), actual.count());
    try expectEqual(@as(u32, 3), actual.get(-1).?);
    try expectEqual(@as(u32, 3), actual.get(-2).?);
    try expectEqual(@as(u32, 3), actual.get(-3).?);
}

test "MemorySegmentManager: computeEffectiveSize (with temp segments) for three segment memory with gaps" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ -3, 2 }, .{1} },
            .{ .{ -3, 5 }, .{1} },
            .{ .{ -3, 7 }, .{1} },
            .{ .{ -2, 1 }, .{1} },
            .{ .{ -1, 2 }, .{1} },
            .{ .{ -1, 4 }, .{1} },
            .{ .{ -1, 7 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(true);

    try expectEqual(@as(usize, 3), actual.count());
    try expectEqual(@as(u32, 8), actual.get(-3).?);
    try expectEqual(@as(u32, 2), actual.get(-2).?);
    try expectEqual(@as(u32, 8), actual.get(-1).?);
}

test "MemorySegmentManager: getSegmentUsedSize after computeEffectiveSize" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 2 }, .{1} },
            .{ .{ 0, 5 }, .{1} },
            .{ .{ 0, 7 }, .{1} },

            .{ .{ 1, 1 }, .{1} },

            .{ .{ 2, 2 }, .{1} },
            .{ .{ 2, 4 }, .{1} },
            .{ .{ 2, 7 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    _ = try memory_segment_manager.computeEffectiveSize(false);

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

test "MemorySegmentManager: relocateSegments for one segment" {
    const allocator = std.testing.allocator;
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(0, 1);
    const actual_value = try memory_segment_manager.relocateSegments(allocator);
    var expected_value = ArrayList(usize).init(allocator);
    defer expected_value.deinit();
    defer allocator.free(actual_value);
    try expected_value.append(1);
    try expectEqualSlices(usize, expected_value.items, actual_value);
}

test "MemorySegmentManager: relocateSegments for ten segments" {
    const allocator = std.testing.allocator;
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(0, 3);
    try memory_segment_manager.segment_used_sizes.put(1, 7);
    try memory_segment_manager.segment_used_sizes.put(2, 12);
    try memory_segment_manager.segment_used_sizes.put(3, 15);
    try memory_segment_manager.segment_used_sizes.put(4, 10);
    try memory_segment_manager.segment_used_sizes.put(5, 17);
    try memory_segment_manager.segment_used_sizes.put(6, 3);
    try memory_segment_manager.segment_used_sizes.put(7, 30);
    try memory_segment_manager.segment_used_sizes.put(8, 55);
    try memory_segment_manager.segment_used_sizes.put(9, 60);
    const actual_value = try memory_segment_manager.relocateSegments(allocator);
    var expected_value = ArrayList(usize).init(std.testing.allocator);
    defer expected_value.deinit();
    defer allocator.free(actual_value);
    try expected_value.append(1); // 1
    try expected_value.append(4); // 3 + 1 = 4
    try expected_value.append(11); // 7 + 4 = 11
    try expected_value.append(23); // 12 + 11 = 23
    try expected_value.append(38); // 15 + 23 = 38
    try expected_value.append(48); // 10 + 38 = 48
    try expected_value.append(65); // 17 + 48 = 65
    try expected_value.append(68); // 3 + 65 = 68
    try expected_value.append(98); // 30 + 68 = 98
    try expected_value.append(153); // 55 + 98 = 153
    try expectEqualSlices(usize, expected_value.items, actual_value);
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
    var value: MaybeRelocatable = .{ .relocatable = Relocatable.init(1, 1) };
    try expect(!memory_segment_manager.isValidMemoryValue(&value));
}

test "MemorySegmentManager: isValidMemoryValue should return true if valid segment" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(0, 10);
    var value: MaybeRelocatable = MaybeRelocatable.fromSegment(0, 5);
    try expect(memory_segment_manager.isValidMemoryValue(&value));
}

test "MemorySegmentManager: getSegmentUsedSize should return null if segments not computed" {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try expectEqual(
        @as(?u32, null),
        memory_segment_manager.getSegmentUsedSize(5),
    );
}

test "MemorySegmentManager: getSegmentUsedSize should return the size of the used segments." {
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(5, 4);
    try memory_segment_manager.segment_used_sizes.put(0, 22);
    try expectEqual(
        @as(?u32, 22),
        memory_segment_manager.getSegmentUsedSize(0),
    );
    try expectEqual(
        @as(?u32, 4),
        memory_segment_manager.getSegmentUsedSize(5),
    );
}

test "MemorySegmentManager: segments utility function for testing test" {
    const allocator = std.testing.allocator;

    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    try segmentsUtil(
        memory_segment_manager,
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{1} },
            .{ .{ 0, 1 }, .{1} },
            .{ .{ 0, 2 }, .{1} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    var actual = try memory_segment_manager.computeEffectiveSize(false);

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 3), actual.get(0).?);
}

test "MemorySegmentManager: loadData with empty data" {
    const allocator = std.testing.allocator;

    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    var data = std.ArrayList(MaybeRelocatable).init(allocator);
    defer data.deinit();

    try expectEqual(
        Relocatable.init(0, 3),
        try memory_segment_manager.loadData(
            allocator,
            Relocatable.init(0, 3),
            data.items,
        ),
    );
}

test "MemorySegmentManager: loadData with one element" {
    const allocator = std.testing.allocator;

    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    var data = std.ArrayList(MaybeRelocatable).init(allocator);
    defer data.deinit();
    try data.append(MaybeRelocatable.fromInt(u8, 4));

    _ = try memory_segment_manager.addSegment();

    const actual = try memory_segment_manager.loadData(
        allocator,
        .{},
        data.items,
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    try expectEqual(Relocatable.init(0, 1), actual);
    try expectEqual(
        MaybeRelocatable.fromInt(u8, 4),
        (memory_segment_manager.memory.get(.{})).?,
    );
}

test "MemorySegmentManager: loadData with three elements" {
    const allocator = std.testing.allocator;

    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    var data = std.ArrayList(MaybeRelocatable).init(allocator);
    defer data.deinit();
    try data.append(MaybeRelocatable.fromInt(u8, 4));
    try data.append(MaybeRelocatable.fromInt(u8, 5));
    try data.append(MaybeRelocatable.fromInt(u8, 6));

    _ = try memory_segment_manager.addSegment();

    const actual = try memory_segment_manager.loadData(
        allocator,
        .{},
        data.items,
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    try expectEqual(Relocatable.init(0, 3), actual);
    try expectEqual(
        MaybeRelocatable.fromInt(u8, 4),
        (memory_segment_manager.memory.get(.{})).?,
    );
    try expectEqual(
        MaybeRelocatable.fromInt(u8, 5),
        (memory_segment_manager.memory.get(Relocatable.init(0, 1))).?,
    );
    try expectEqual(
        MaybeRelocatable.fromInt(u8, 6),
        (memory_segment_manager.memory.get(Relocatable.init(0, 2))).?,
    );
}

test "MemorySegmentManager: getPublicMemoryAddresses with correct segment offsets" {
    // Initialize the allocator for testing purposes.
    const allocator = std.testing.allocator;

    // Initialize the MemorySegmentManager and ensure it's properly deallocated at the end.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    // Add five segments to the memory segment manager.
    for (0..5) |_| {
        _ = try memory_segment_manager.addSegment();
    }

    // Initialize lists to hold public memory offsets.
    var public_memory_offsets = std.ArrayList(?std.ArrayList(Tuple(&.{ usize, usize }))).init(allocator);
    defer public_memory_offsets.deinit();

    // Initialize inner lists to store specific offsets for segments.
    var inner_list_1 = std.ArrayList(Tuple(&.{ usize, usize })).init(allocator);
    defer inner_list_1.deinit();
    try inner_list_1.append(.{ 0, 0 });
    try inner_list_1.append(.{ 1, 1 });

    var inner_list_2 = std.ArrayList(Tuple(&.{ usize, usize })).init(allocator);
    defer inner_list_2.deinit();
    inline for (0..8) |i| {
        try inner_list_2.append(.{ i, 0 });
    }

    var inner_list_5 = std.ArrayList(Tuple(&.{ usize, usize })).init(allocator);
    defer inner_list_5.deinit();
    try inner_list_5.append(.{ 1, 2 });

    // Append inner lists containing offsets to public_memory_offsets.
    try public_memory_offsets.append(inner_list_1);
    try public_memory_offsets.append(inner_list_2);
    try public_memory_offsets.append(null);
    try public_memory_offsets.append(null);
    try public_memory_offsets.append(inner_list_5);

    // Perform assertions and memory operations.
    try expectEqual(
        memory_segment_manager.addSegment(),
        Relocatable.init(5, 0),
    );
    try expectEqual(
        memory_segment_manager.addSegment(),
        Relocatable.init(6, 0),
    );
    try memory_segment_manager.memory.set(
        allocator,
        Relocatable.init(5, 4),
        MaybeRelocatable.fromInt(u8, 0),
    );
    defer memory_segment_manager.memory.deinitData(allocator);

    // Finalize segments with sizes and offsets.
    for ([_]u8{ 3, 8, 0, 1, 2 }, 0..) |size, i| {
        try memory_segment_manager.finalize(
            i,
            size,
            public_memory_offsets.items[i],
        );
    }

    // Create and populate segment_offsets list.
    var segment_offsets = std.ArrayList(usize).init(allocator);
    defer segment_offsets.deinit();
    for ([_]usize{ 1, 4, 12, 12, 13, 15, 20 }) |offset| {
        try segment_offsets.append(offset);
    }

    // Get public memory addresses based on segment offsets.
    const public_memory_addresses = try memory_segment_manager.getPublicMemoryAddresses(&segment_offsets);
    defer public_memory_addresses.deinit();
    const expected = [_]Tuple(&.{ usize, usize }){
        .{ 1, 0 },
        .{ 2, 1 },
        .{ 4, 0 },
        .{ 5, 0 },
        .{ 6, 0 },
        .{ 7, 0 },
        .{ 8, 0 },
        .{ 9, 0 },
        .{ 10, 0 },
        .{ 11, 0 },
        .{ 14, 2 },
    };

    // Assert equality of expected and retrieved public memory addresses.
    try expectEqualSlices(
        Tuple(&.{ usize, usize }),
        &expected,
        public_memory_addresses.items,
    );
}

test "MemorySegmentManager: getPublicMemoryAddresses with incorrect segment offsets. Throws MalformedPublicMemory" {
    // Initialize the allocator for testing purposes.
    const allocator = std.testing.allocator;

    // Initialize the MemorySegmentManager and ensure it's properly deallocated at the end.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    // Add five segments to the memory segment manager.
    for (0..5) |_| {
        _ = try memory_segment_manager.addSegment();
    }

    // Initialize lists to hold public memory offsets.
    var public_memory_offsets = std.ArrayList(?std.ArrayList(Tuple(&.{ usize, usize }))).init(allocator);
    defer public_memory_offsets.deinit();

    // Initialize inner lists to store specific offsets for segments.
    var inner_list_1 = std.ArrayList(Tuple(&.{ usize, usize })).init(allocator);
    defer inner_list_1.deinit();
    try inner_list_1.append(.{ 0, 0 });
    try inner_list_1.append(.{ 1, 1 });

    var inner_list_2 = std.ArrayList(Tuple(&.{ usize, usize })).init(allocator);
    defer inner_list_2.deinit();
    inline for (0..8) |i| {
        try inner_list_2.append(.{ i, 0 });
    }

    var inner_list_5 = std.ArrayList(Tuple(&.{ usize, usize })).init(allocator);
    defer inner_list_5.deinit();
    try inner_list_5.append(.{ 1, 2 });

    // Append inner lists containing offsets to public_memory_offsets.
    try public_memory_offsets.append(inner_list_1);
    try public_memory_offsets.append(inner_list_2);
    try public_memory_offsets.append(null);
    try public_memory_offsets.append(null);
    try public_memory_offsets.append(inner_list_5);

    // Perform assertions and memory operations.
    try expectEqual(
        memory_segment_manager.addSegment(),
        Relocatable.init(5, 0),
    );
    try expectEqual(
        memory_segment_manager.addSegment(),
        Relocatable.init(6, 0),
    );
    try memory_segment_manager.memory.set(
        allocator,
        Relocatable.init(5, 4),
        MaybeRelocatable.fromInt(u8, 0),
    );
    defer memory_segment_manager.memory.deinitData(allocator);

    // Finalize segments with sizes and offsets.
    for ([_]u8{ 3, 8, 0, 1, 2 }, 0..) |size, i| {
        try memory_segment_manager.finalize(
            i,
            size,
            public_memory_offsets.items[i],
        );
    }

    // Create and populate segment_offsets list with incorrect offsets.
    var segment_offsets = std.ArrayList(usize).init(allocator);
    defer segment_offsets.deinit();
    // Segment offsets less than the number of segments.
    for ([_]usize{ 1, 4, 12, 13 }) |offset| {
        try segment_offsets.append(offset);
    }

    // Validate if the function throws the expected MemoryError.MalformedPublicMemory.
    try expectError(
        MemoryError.MalformedPublicMemory,
        memory_segment_manager.getPublicMemoryAddresses(&segment_offsets),
    );
}

test "MemorySegmentManager: writeArg with apply modulo" {
    // Initialize allocator for testing
    const allocator = std.testing.allocator;

    // Initialize MemorySegmentManager
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    // Prepare data with MaybeRelocatable values
    var data = std.ArrayList(MaybeRelocatable).init(allocator);
    defer data.deinit();

    // Add MaybeRelocatable values to data array
    try data.append(MaybeRelocatable.fromInt(u256, 11));
    try data.append(MaybeRelocatable.fromInt(u256, 12));
    try data.append(MaybeRelocatable.fromInt(u256, 3618502788666131213697322783095070105623107215331596699973092056135872020482));

    // Add segments to the memory segment manager
    for (0..2) |_| {
        _ = try memory_segment_manager.addSegment();
    }

    // Perform the writeArg operation
    const exec = try memory_segment_manager.writeArg(
        std.ArrayList(MaybeRelocatable),
        Relocatable.init(1, 0),
        &data,
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    // Prepare the expected data
    var expected_data = std.ArrayList(?MemoryCell).init(std.testing.allocator);
    defer expected_data.deinit();

    try expected_data.append(MemoryCell.init(MaybeRelocatable.fromInt(u256, 11)));
    try expected_data.append(MemoryCell.init(MaybeRelocatable.fromInt(u256, 12)));
    try expected_data.append(MemoryCell.init(MaybeRelocatable.fromInt(u8, 1)));

    // Perform assertions
    try expectEqual(
        MaybeRelocatable.fromSegment(1, 3),
        exec,
    );
    try expectEqualSlices(
        ?MemoryCell,
        expected_data.items,
        memory_segment_manager.memory.data.items[1].items,
    );
}

test "MemorySegmentManager: writeArg with Relocatable" {
    // (same comments structure as previous test, adapted to this scenario)

    // Initialize allocator for testing
    const allocator = std.testing.allocator;

    // Initialize MemorySegmentManager
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    // Prepare data with Relocatable values
    var data = std.ArrayList(Relocatable).init(allocator);
    defer data.deinit();

    // Add Relocatable values to data array
    try data.append(Relocatable.init(0, 1));
    try data.append(Relocatable.init(0, 2));
    try data.append(Relocatable.init(0, 3));

    // Add segments to the memory segment manager
    for (0..2) |_| {
        _ = try memory_segment_manager.addSegment();
    }

    // Perform the writeArg operation
    const exec = try memory_segment_manager.writeArg(
        std.ArrayList(Relocatable),
        Relocatable.init(1, 0),
        &data,
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    // Prepare the expected data
    var expected_data = std.ArrayList(?MemoryCell).init(std.testing.allocator);
    defer expected_data.deinit();

    try expected_data.append(MemoryCell.init(MaybeRelocatable.fromSegment(0, 1)));
    try expected_data.append(MemoryCell.init(MaybeRelocatable.fromSegment(0, 2)));
    try expected_data.append(MemoryCell.init(MaybeRelocatable.fromSegment(0, 3)));

    // Perform assertions
    try expectEqual(
        MaybeRelocatable.fromSegment(1, 3),
        exec,
    );
    try expectEqualSlices(
        ?MemoryCell,
        expected_data.items,
        memory_segment_manager.memory.data.items[1].items,
    );
}

test "MemorySegmentManager: writeArg should return memory error if type is not vec of MaybeRelocatable or Relocatable" {
    // (same comments structure as previous tests, adapted to this scenario)

    // Initialize allocator for testing
    const allocator = std.testing.allocator;

    // Initialize MemorySegmentManager
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    // Prepare unsupported data type
    var arg: u64 = 10;

    // Perform the writeArg operation with unsupported data type
    try expectError(
        MemoryError.WriteArg,
        memory_segment_manager.writeArg(
            u64,
            Relocatable.init(1, 0),
            &arg,
        ),
    );
}

test "MemorySegmentManager: getMemoryHoles with missing segment used sizes" {
    const allocator = std.testing.allocator;

    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 0, 0 }, .{0} }},
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    memory_segment_manager.memory.markAsAccessed(.{});

    try expectError(
        MemoryError.MissingSegmentUsedSizes,
        memory_segment_manager.getMemoryHoles(0, false),
    );
}

test "MemorySegmentManager: getMemoryHoles with out of address offset that is bigger than size" {
    const allocator = std.testing.allocator;

    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(0, 2);

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{0} },
            .{ .{ 0, 1 }, .{1} },
            .{ .{ 0, 2 }, .{2} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    for (0..3) |i| {
        memory_segment_manager.memory.markAsAccessed(Relocatable.init(0, i));
    }

    try expectError(
        MemoryError.SegmentHasMoreAccessedAddressesThanSize,
        memory_segment_manager.getMemoryHoles(0, false),
    );
}

test "MemorySegmentManager: getMemoryHoles that is empty should return 0" {
    const allocator = std.testing.allocator;

    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();

    try expectEqual(
        @as(usize, 0),
        try memory_segment_manager.getMemoryHoles(0, false),
    );

    try memory_segment_manager.segment_used_sizes.put(0, 4);

    try expectEqual(
        @as(usize, 0),
        try memory_segment_manager.getMemoryHoles(0, false),
    );
}

test "MemorySegmentManager: getMemoryHoles with two memory holes" {
    const allocator = std.testing.allocator;

    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(0, 10);

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{0} },
            .{ .{ 0, 1 }, .{0} },
            .{ .{ 0, 2 }, .{0} },
            .{ .{ 0, 3 }, .{0} },
            .{ .{ 0, 6 }, .{0} },
            .{ .{ 0, 7 }, .{0} },
            .{ .{ 0, 8 }, .{0} },
            .{ .{ 0, 9 }, .{0} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    for ([_]usize{ 0, 1, 2, 3, 6, 7, 8, 9 }) |i| {
        memory_segment_manager.memory.markAsAccessed(Relocatable.init(0, i));
    }

    try expectEqual(
        @as(usize, 2),
        try memory_segment_manager.getMemoryHoles(0, false),
    );
}

test "MemorySegmentManager: getMemoryHoles with seven memory holes" {
    const allocator = std.testing.allocator;

    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_sizes.put(0, 15);
    try memory_segment_manager.segment_used_sizes.put(0, 10);

    try memory_segment_manager.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{0} },
            .{ .{ 0, 1 }, .{0} },
            .{ .{ 0, 2 }, .{0} },
            .{ .{ 0, 3 }, .{0} },
            .{ .{ 0, 4 }, .{0} },
            .{ .{ 0, 5 }, .{0} },
            .{ .{ 0, 6 }, .{0} },
            .{ .{ 0, 7 }, .{0} },
            .{ .{ 0, 8 }, .{0} },
            .{ .{ 0, 9 }, .{0} },
        },
    );
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    for ([_]usize{ 0, 1, 2, 3, 6, 7, 8, 9 }) |i| {
        memory_segment_manager.memory.markAsAccessed(Relocatable.init(0, i));
    }

    try expectEqual(
        @as(usize, 7),
        try memory_segment_manager.getMemoryHoles(0, false),
    );
}

test "MemorySegmentManager: genArg with a relocatable value should pass the value through" {
    // Define the allocator for testing purposes.
    const allocator = std.testing.allocator;

    // Initialize a MemorySegmentManager instance for testing.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    // Defer its deinitialization to ensure proper cleanup.
    defer memory_segment_manager.deinit();

    // Create a MaybeRelocatable value from a segment (0, 0) for testing.
    var maybe_relocatable = MaybeRelocatable.fromSegment(0, 0);

    // Test that the genArg function passes the MaybeRelocatable value through.
    try expectEqual(
        MaybeRelocatable.fromSegment(0, 0),
        try memory_segment_manager.genArg(MaybeRelocatable, &maybe_relocatable),
    );
}

test "MemorySegmentManager: genArg with a big int value should pass the value through" {
    // Define the allocator for testing purposes.
    const allocator = std.testing.allocator;

    // Initialize a MemorySegmentManager instance for testing.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    // Defer its deinitialization to ensure proper cleanup.
    defer memory_segment_manager.deinit();

    // Create a MaybeRelocatable value from a U256 big int value (1234) for testing.
    var maybe_relocatable = MaybeRelocatable.fromInt(u256, 1234);

    // Test that the genArg function passes the MaybeRelocatable value through.
    try expectEqual(
        MaybeRelocatable.fromInt(u256, 1234),
        try memory_segment_manager.genArg(MaybeRelocatable, &maybe_relocatable),
    );
}

test "MemorySegmentManager: genArg with a vector of MaybeRelocatable should write its content into a new segment and returns a pointer to it." {
    // Define the allocator for testing purposes.
    const allocator = std.testing.allocator;

    // Initialize a MemorySegmentManager instance for testing.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    // Defer its deinitialization to ensure proper cleanup.
    defer memory_segment_manager.deinit();

    // Initialize a vector of MaybeRelocatable for testing.
    var vec = std.ArrayList(MaybeRelocatable).init(std.testing.allocator);
    // Defer its deinitialization to ensure proper cleanup.
    defer vec.deinit();

    // Append various MaybeRelocatable values to the vector for testing purposes.
    try vec.append(MaybeRelocatable.fromInt(u8, 0));
    try vec.append(MaybeRelocatable.fromInt(u8, 1));
    try vec.append(MaybeRelocatable.fromInt(u8, 2));
    try vec.append(MaybeRelocatable.fromInt(u256, 3));
    try vec.append(MaybeRelocatable.fromSegment(0, 0));
    try vec.append(MaybeRelocatable.fromSegment(0, 1));
    try vec.append(MaybeRelocatable.fromSegment(0, 2));
    try vec.append(MaybeRelocatable.fromSegment(0, 3));

    // Execute the genArg function with the vector and store the result.
    const actual = try memory_segment_manager.genArg(std.ArrayList(MaybeRelocatable), &vec);
    // Defer the deinitialization of MemorySegmentManager's memory to ensure proper cleanup.
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    // Test that the genArg function writes the content of the vector into a new segment and returns a pointer to it.
    try expectEqual(
        MaybeRelocatable.fromSegment(0, 0),
        actual,
    );
}

test "MemorySegmentManager: genArg with a vector of Relocatable should write its content into a new segment and returns a pointer to it." {
    // Define the allocator for testing purposes.
    const allocator = std.testing.allocator;

    // Initialize a MemorySegmentManager instance for testing.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    // Defer its deinitialization to ensure proper cleanup.
    defer memory_segment_manager.deinit();

    // Initialize a vector of Relocatable for testing.
    var vec = std.ArrayList(Relocatable).init(std.testing.allocator);
    // Defer its deinitialization to ensure proper cleanup.
    defer vec.deinit();

    // Append various Relocatable values to the vector for testing purposes.
    try vec.append(.{});
    try vec.append(Relocatable.init(0, 1));
    try vec.append(Relocatable.init(0, 2));
    try vec.append(Relocatable.init(0, 3));

    // Execute the genArg function with the vector and store the result.
    const actual = try memory_segment_manager.genArg(std.ArrayList(Relocatable), &vec);
    // Defer the deinitialization of MemorySegmentManager's memory to ensure proper cleanup.
    defer memory_segment_manager.memory.deinitData(std.testing.allocator);

    // Test that the genArg function writes the content of the vector into a new segment and returns a pointer to it.
    try expectEqual(
        MaybeRelocatable.fromSegment(0, 0),
        actual,
    );
}

test "MemorySegmentManager: genArg with invalid type should throw an error" {
    // Define the allocator for testing purposes.
    const allocator = std.testing.allocator;

    // Initialize a MemorySegmentManager instance for testing.
    var memory_segment_manager = try MemorySegmentManager.init(allocator);
    // Defer its deinitialization to ensure proper cleanup.
    defer memory_segment_manager.deinit();

    // Define an invalid argument of type u64 for testing.
    var arg: u64 = 10;

    // Test that calling genArg with an invalid type throws the expected error.
    try expectError(
        MemoryError.GenArgInvalidType, // Expected error type when using an invalid type.
        memory_segment_manager.genArg(u64, &arg), // Attempting to use an invalid type with genArg.
    );
}
