const std = @import("std");
const relocatable = @import("../vm/memory/relocatable.zig");

const CairoVM = @import("../vm/core.zig").CairoVM;
const MaybeRelocatable = relocatable.MaybeRelocatable;
const IdsManager = @import("hint_utils.zig").IdsManager;
const HintReference = @import("../hint_processor/hint_processor_def.zig").HintReference;

pub fn setupIdsNonContinuousIdsData(allocator: std.mem.Allocator, data: []const struct { []const u8, i32 }) !std.StringHashMap(HintReference) {
    var ids_data = std.StringHashMap(HintReference).init(allocator);
    errdefer ids_data.deinit();

    for (data) |d| {
        try ids_data.put(d[0], HintReference.initSimple(d[1]));
    }

    return ids_data;
}

pub fn setupIdsForTestWithoutMemory(allocator: std.mem.Allocator, data: []const []const u8) !std.StringHashMap(HintReference) {
    var result = std.StringHashMap(HintReference).init(allocator);
    errdefer result.deinit();

    for (data, 0..) |name, idx| {
        try result.put(name, HintReference.initSimple(@as(i32, @intCast(idx)) - @as(i32, @intCast(data.len))));
    }

    return result;
}

pub fn setupIdsForTest(allocator: std.mem.Allocator, data: []const struct { name: []const u8, elems: []const ?MaybeRelocatable }, vm: *CairoVM) !std.StringHashMap(HintReference) {
    var result = std.StringHashMap(HintReference).init(allocator);
    errdefer result.deinit();

    var current_offset: usize = 0;
    var base_addr = vm.run_context.getFP();
    _ = try vm.addMemorySegment();

    for (data) |d| {
        try result.put(d.name, .{
            .dereference = true,
            .offset1 = .{
                .reference = .{ .FP, @intCast(current_offset), false },
            },
        });
        // update current offset
        current_offset = current_offset + d.elems.len;

        // Insert ids variables
        for (d.elems, 0..) |elem, n| {
            if (elem) |val| {
                try vm.insertInMemory(
                    allocator,
                    try base_addr.addUint(n),
                    val,
                );
            }
        }

        // Update base_addr
        base_addr.offset = base_addr.offset + d.elems.len;
    }

    return result;
}
