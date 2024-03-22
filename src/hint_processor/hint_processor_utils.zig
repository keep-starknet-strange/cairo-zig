const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const Register = @import("../vm/instructions.zig").Register;
const ApTracking = @import("../vm/types/programjson.zig").ApTracking;
const Felt252 = @import("../math/fields/starknet.zig").Felt252;
const HintReference = @import("hint_processor_def.zig").HintReference;
const CoreVM = @import("../vm/core.zig");
const OffsetValue = @import("../vm/types/programjson.zig").OffsetValue;
const CairoVM = CoreVM.CairoVM;
const MaybeRelocatable = @import("../vm/memory/relocatable.zig").MaybeRelocatable;
const Relocatable = @import("../vm/memory/relocatable.zig").Relocatable;
const Allocator = std.mem.Allocator;
const HintError = @import("../vm/error.zig").HintError;

///Inserts value into the address of the given ids variable
pub fn insertValueFromReference(
    allocator: Allocator,
    value: MaybeRelocatable,
    vm: *CairoVM,
    hint_reference: HintReference,
    ap_tracking: ApTracking,
) !void {
    if (computeAddrFromReference(hint_reference, ap_tracking, vm)) |var_addr| {
        vm.segments.memory.set(allocator, var_addr, value) catch HintError.Memory;
    } else return HintError.UnknownIdentifierInternal;
}

/// Retrieves the integer value stored in the given ids variable.
///
/// This function retrieves the integer value stored in the given ids variable indicated by the provided `hint_reference`.
/// If the value is stored as an immediate, it returns the value directly.
/// Otherwise, it computes the memory address of the variable and retrieves the integer value from memory.
///
/// # Parameters
/// - `vm`: A pointer to the Cairo virtual machine.
/// - `hint_reference`: The hint reference indicating the variable.
/// - `ap_tracking`: The AP tracking data.
///
/// # Returns
/// Returns the integer value stored in the variable indicated by the hint reference.
/// If the variable is not found or if there's an error retrieving the value, it returns an error of type `HintError`.
pub fn getIntegerFromReference(
    vm: *CairoVM,
    hint_reference: HintReference,
    ap_tracking: ApTracking,
) !Felt252 {
    // If the reference register is none, this means it is an immediate value, and we should return that value.
    switch (hint_reference.offset1) {
        .immediate => |int_1| return int_1,
        else => {},
    }

    // Compute the memory address of the variable and retrieve the integer value from memory.
    return if (computeAddrFromReference(hint_reference, ap_tracking, vm)) |var_addr|
        vm.segments.memory.getFelt(var_addr) catch HintError.WrongIdentifierTypeInternal
    else
        HintError.UnknownIdentifierInternal;
}

/// Retrieves the Relocatable value stored in the given ids variable.
///
/// This function retrieves the Relocatable value stored in the given ids variable indicated by the provided `hint_reference`.
/// If the value is stored as an immediate, it returns the value directly.
/// Otherwise, it computes the memory address of the variable and retrieves the Relocatable value from memory.
///
/// # Parameters
/// - `hint_reference`: The hint reference indicating the variable.
/// - `ap_tracking`: The AP tracking data.
/// - `vm`: A pointer to the Cairo virtual machine.
///
/// # Returns
/// Returns the Relocatable value stored in the variable indicated by the hint reference.
/// If the variable is not found or if there's an error retrieving the value, it returns an error of type `HintError`.
pub fn getPtrFromReference(
    hint_reference: HintReference,
    ap_tracking: ApTracking,
    vm: *CairoVM,
) !Relocatable {
    const var_addr = computeAddrFromReference(hint_reference, ap_tracking, vm) orelse
        return HintError.UnknownIdentifierInternal;

    return if (hint_reference.dereference)
        vm.getRelocatable(var_addr) catch HintError.WrongIdentifierTypeInternal
    else
        var_addr;
}

/// Adjusts the memory address using AP tracking correction.
///
/// This function adjusts the memory address `addr` based on the AP tracking information provided.
/// It calculates the correction by subtracting the offset of the reference AP tracking from the offset of the hint AP tracking.
/// If both AP trackings belong to the same group, it returns the adjusted address.
/// Otherwise, it returns `null`.
///
/// # Parameters
/// - `addr`: The original memory address.
/// - `ref_ap_tracking`: The AP tracking data of the reference.
/// - `hint_ap_tracking`: The AP tracking data of the hint.
///
/// # Returns
/// Returns the adjusted memory address if both AP trackings belong to the same group.
/// Otherwise, returns `null`.
pub fn applyApTrackingCorrection(
    addr: Relocatable,
    ref_ap_tracking: ApTracking,
    hint_ap_tracking: ApTracking,
) ?Relocatable {
    return if (ref_ap_tracking.group == hint_ap_tracking.group)
        addr.subUint(hint_ap_tracking.offset - ref_ap_tracking.offset) catch null
    else
        null;
}

/// Retrieves the memory value from a reference with an offset.
///
/// This function retrieves the memory value indicated by the provided `hint_reference` with the specified `offset_value`.
/// It calculates the memory address based on the offset value and AP tracking information.
/// If the offset value is a reference, it ensures it's within bounds and calculates the base address accordingly.
/// Then, it retrieves the memory value from the calculated address.
///
/// # Parameters
/// - `vm`: A pointer to the Cairo virtual machine.
/// - `hint_reference`: The hint reference indicating the variable.
/// - `hint_ap_tracking`: The AP tracking data for the hint reference.
/// - `offset_value`: The offset value to apply to the reference.
///
/// # Returns
/// Returns the memory value indicated by the hint reference with the specified offset value as a `MaybeRelocatable`.
/// If the reference is not valid or if there's an error retrieving the value, it returns `null`.
pub fn getOffsetValueReference(
    vm: *CairoVM,
    hint_reference: HintReference,
    hint_ap_tracking: ApTracking,
    offset_value: OffsetValue,
) ?MaybeRelocatable {
    // Extract the reference from the offset value.
    const refer = switch (offset_value) {
        .reference => |ref| ref,
        else => return null,
    };

    // Calculate the base address based on the reference type.
    const base_addr = switch (refer[0]) {
        .FP => vm.run_context.getFP(),
        else => applyApTrackingCorrection(
            vm.run_context.getAP(),
            hint_reference.ap_tracking_data orelse return null,
            hint_ap_tracking,
        ) orelse return null,
    };

    // Calculate the final memory address and retrieve the value.
    return if (refer[2])
        vm.segments.memory.get(base_addr.addInt(@intCast(refer[1])) catch return null) orelse null
    else
        MaybeRelocatable.fromRelocatable(base_addr.addInt(@intCast(refer[1])) catch return null);
}

/// Computes the memory address indicated by the provided hint reference.
///
/// This function takes a hint reference, which is a complex data structure indicating the address
/// of a variable within the Cairo virtual machine's memory. The function computes this address
/// by following the instructions encoded in the hint reference.
///
/// # Parameters
/// - `hint_reference`: The hint reference indicating the address.
/// - `hint_ap_tracking`: The AP tracking data associated with the hint reference.
/// - `vm`: A pointer to the Cairo virtual machine.
///
/// # Returns
/// Returns the computed memory address as a `Relocatable` if successful, or `null` if the address
/// could not be computed.
pub fn computeAddrFromReference(
    hint_reference: HintReference,
    hint_ap_tracking: ApTracking,
    vm: *CairoVM,
) ?Relocatable {
    // Extract the first offset value from the hint reference.
    const offset1 = switch (hint_reference.offset1) {
        .reference => if (getOffsetValueReference(
            vm,
            hint_reference,
            hint_ap_tracking,
            hint_reference.offset1,
        )) |v|
            // Convert the offset value to a relocatable address.
            v.intoRelocatable() catch return null
        else
            return null,
        else => return null,
    };

    // Compute the memory address based on the second offset value or a constant value.
    return switch (hint_reference.offset2) {
        .reference => blk: {
            // If the second offset is a reference, it must be resolved.
            const value = getOffsetValueReference(
                vm,
                hint_reference,
                hint_ap_tracking,
                hint_reference.offset2,
            ) orelse return null;

            // Convert the offset value to an unsigned 64-bit integer.
            const value_int = value.intoU64() catch return null;

            // Add the offset value to the base address.
            break :blk offset1.addUint(value_int) catch return null;
        },
        .value => |val| offset1.addInt(val) catch null,
        else => null,
    };
}

/// Returns the value given by a reference as `MaybeRelocatable`.
///
/// This function retrieves the value indicated by the provided `hint_reference` as a `MaybeRelocatable`.
/// If the value is stored as an immediate, it returns the value directly.
/// Otherwise, it computes the memory address of the variable and retrieves the value from memory.
///
/// # Parameters
/// - `vm`: A pointer to the Cairo virtual machine.
/// - `hint_reference`: The hint reference indicating the variable.
/// - `ap_tracking`: The AP tracking data.
///
/// # Returns
/// Returns the value indicated by the hint reference as a `MaybeRelocatable`.
/// If the variable is not found or if there's an error retrieving the value, it returns `null`.
pub fn getMaybeRelocatableFromReference(
    vm: *CairoVM,
    hint_reference: HintReference,
    ap_tracking: ApTracking,
) ?MaybeRelocatable {
    // First handle the case of an immediate value.
    switch (hint_reference.offset1) {
        .immediate => |num| return MaybeRelocatable.fromFelt(num),
        else => {},
    }

    // Then calculate the memory address.
    return if (computeAddrFromReference(hint_reference, ap_tracking, vm)) |var_addr|
        if (hint_reference.dereference)
            vm.segments.memory.get(var_addr)
        else
            MaybeRelocatable.fromRelocatable(var_addr)
    else
        null;
}

test "computeAddrFromReference: no register in reference" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up memory segments in the virtual machine.
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 1, 0 }, .{ 4, 0 } }},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator); // Clean up memory data.

    // Create a hint reference with no register information.
    var hint_reference = HintReference.init(0, 0, false, false);
    // Set the immediate offset value to 2.
    hint_reference.offset1 = .{ .immediate = Felt252.fromInt(u8, 2) };

    // Ensure that the computed address is null, as no register information is provided.
    try expectEqual(null, computeAddrFromReference(hint_reference, .{}, &vm));
}

test "computeAddrFromReference: failed to get ids" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up memory segments in the virtual machine.
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 1, 0 }, .{4} }},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator); // Clean up memory data.

    // Create a hint reference with register information pointing to the frame pointer (FP).
    var hint_reference = HintReference.init(0, 0, false, false);
    // Set the reference offset to point to an unknown location relative to the frame pointer.
    hint_reference.offset1 = .{ .reference = .{ .FP, -1, true } };

    // Ensure that the computed address is null due to failure in retrieving the ids variable.
    try expectEqual(null, computeAddrFromReference(hint_reference, .{}, &vm));
}

test "getIntegerFromReference: with immediate value" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up memory segments in the virtual machine.
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 1, 0 }, .{0} }},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator); // Clean up memory data.

    // Create a hint reference with an immediate value.
    var hint_reference = HintReference.init(0, 0, false, true);
    hint_reference.offset1 = .{ .immediate = Felt252.fromInt(u8, 2) };

    // Assert that the integer value retrieved from the reference is equal to the expected value.
    try expectEqual(
        Felt252.fromInt(u8, 2),
        getIntegerFromReference(&vm, hint_reference, .{}),
    );
}

test "getPtrFromReference: short path" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Verify that the function returns the expected Relocatable value for a short path.
    try expectEqual(
        Relocatable.init(1, 0),
        try getPtrFromReference(HintReference.init(0, 0, false, false), .{}, &vm),
    );
}

test "getPtrFromReference: with dereference" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up memory segments in the virtual machine.
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 1, 0 }, .{ 3, 0 } }},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator); // Clean up memory data.

    // Verify that the function returns the expected Relocatable value with dereference.
    try expectEqual(
        Relocatable.init(3, 0),
        try getPtrFromReference(HintReference.init(0, 0, false, true), .{}, &vm),
    );
}

test "getPtrFromReference: with dereference and immediate value" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up memory segments in the virtual machine.
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 1, 0 }, .{ 4, 0 } }},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator); // Clean up memory data.

    // Create a hint reference with immediate value and verify the function returns the expected Relocatable value.
    var hint_ref = HintReference.init(0, 0, true, false);
    hint_ref.offset2 = .{ .value = 2 };

    try expectEqual(
        Relocatable.init(4, 2),
        try getPtrFromReference(hint_ref, .{}, &vm),
    );
}

test "applyApTrackingCorrection: with valid correction" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up reference and hint AP tracking with the same group.
    var ref_ap_tracking: ApTracking = .{};
    ref_ap_tracking.group = 1;
    var hint_ap_tracking: ApTracking = .{};
    hint_ap_tracking.group = 1;

    // Verify that the function returns the adjusted address when both AP trackings have the same group.
    try expectEqual(
        Relocatable.init(1, 0),
        applyApTrackingCorrection(Relocatable.init(1, 0), ref_ap_tracking, hint_ap_tracking),
    );
}

test "applyApTrackingCorrection: with invalid group" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up reference and hint AP tracking with different groups.
    var ref_ap_tracking: ApTracking = .{};
    ref_ap_tracking.group = 1;
    var hint_ap_tracking: ApTracking = .{};
    hint_ap_tracking.group = 2;

    // Verify that the function returns `null` when both AP trackings have different groups.
    try expectEqual(
        null,
        applyApTrackingCorrection(Relocatable.init(1, 0), ref_ap_tracking, hint_ap_tracking),
    );
}

test "applyApTrackingCorrection: with valid group but invalid address subtraction" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up reference and hint AP tracking with the same group but incompatible offsets.
    var ref_ap_tracking: ApTracking = .{};
    ref_ap_tracking.group = 2;
    ref_ap_tracking.offset = 5;
    var hint_ap_tracking: ApTracking = .{};
    hint_ap_tracking.group = 2;
    hint_ap_tracking.offset = 10;

    // Verify that the function returns `null` when both AP trackings have the same group but incompatible offsets.
    try expectEqual(
        null,
        applyApTrackingCorrection(Relocatable.init(1, 0), ref_ap_tracking, hint_ap_tracking),
    );
}

test "getMaybeRelocatableFromReference: valid" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up memory segments in the virtual machine.
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 1, 0 }, .{ 0, 0 } }},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator); // Clean up memory data.

    // Verify that the function returns the expected `MaybeRelocatable` value.
    try expectEqual(
        MaybeRelocatable.fromSegment(0, 0),
        getMaybeRelocatableFromReference(&vm, HintReference.initSimple(0), .{}),
    );
}

test "getMaybeRelocatableFromReference: invalid" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Verify that the function returns `null` when provided with invalid input.
    try expectEqual(
        null,
        getMaybeRelocatableFromReference(&vm, HintReference.initSimple(0), .{}),
    );
}

test "getOffsetValueReference: valid" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up memory segments in the virtual machine.
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 1, 0 }, .{0} }},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator); // Clean up memory data.

    var hint_reference = HintReference.init(0, 0, false, true);
    hint_reference.offset1 = .{ .reference = .{ .FP, 2, false } };

    // Verify that the function returns the expected `MaybeRelocatable` value.
    try expectEqual(
        MaybeRelocatable.fromSegment(1, 2),
        getOffsetValueReference(&vm, hint_reference, .{}, hint_reference.offset1),
    );
}

test "getOffsetValueReference: invalid" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    // Set up memory segments in the virtual machine.
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 1, 0 }, .{0} }},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator); // Clean up memory data.

    var hint_reference = HintReference.init(0, 0, false, true);
    hint_reference.offset1 = .{ .reference = .{ .FP, -2, false } };

    // Verify that the function returns `null` when provided with invalid input.
    try expectEqual(
        null,
        getOffsetValueReference(&vm, hint_reference, .{}, hint_reference.offset1),
    );
}

test "getOffsetValueReference: null hint reference AP tracking data" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    var hint_reference = HintReference.init(0, 0, false, true);
    hint_reference.offset1 = .{ .reference = .{ .AP, 2, false } };

    // Verify that the function returns `null` when the hint reference AP tracking data is null.
    try expectEqual(
        null,
        getOffsetValueReference(&vm, hint_reference, .{}, hint_reference.offset1),
    );
}

test "getOffsetValueReference: with null applyApTrackingCorrection" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    var hint_reference = HintReference.init(0, 0, false, true);
    hint_reference.offset1 = .{ .reference = .{ .AP, 2, false } };
    hint_reference.ap_tracking_data = .{};
    hint_reference.ap_tracking_data.?.group = 10;

    // Verify that the function returns `null` when `applyApTrackingCorrection` returns null.
    try expectEqual(
        null,
        getOffsetValueReference(&vm, hint_reference, .{}, hint_reference.offset1),
    );
}

test "getOffsetValueReference: valid but nothing in memory" {
    // Initialize the Cairo virtual machine.
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit(); // Ensure cleanup.

    var hint_reference = HintReference.init(0, 0, false, true);
    hint_reference.offset1 = .{ .reference = .{ .FP, 2, true } };

    // Verify that the function returns `null` when there is no data in memory.
    try expectEqual(
        null,
        getOffsetValueReference(&vm, hint_reference, .{}, hint_reference.offset1),
    );
}
