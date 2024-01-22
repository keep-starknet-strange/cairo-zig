// Core imports.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const starknet_felt = @import("../math/fields/starknet.zig");

// Local imports.
const segments = @import("memory/segments.zig");
const memory = @import("memory/memory.zig");
const MemoryCell = memory.MemoryCell;
const relocatable = @import("memory/relocatable.zig");
const MaybeRelocatable = relocatable.MaybeRelocatable;
const Relocatable = relocatable.Relocatable;
const instructions = @import("instructions.zig");
const RunContext = @import("run_context.zig").RunContext;
const CairoVMError = @import("error.zig").CairoVMError;
const TraceError = @import("error.zig").TraceError;
const MemoryError = @import("error.zig").MemoryError;
const MathError = @import("error.zig").MathError;
const Config = @import("config.zig").Config;
const TraceContext = @import("trace_context.zig").TraceContext;
const build_options = @import("../build_options.zig");
const BuiltinRunner = @import("./builtins/builtin_runner/builtin_runner.zig").BuiltinRunner;
const BitwiseBuiltinRunner = @import("./builtins/builtin_runner/bitwise.zig").BitwiseBuiltinRunner;
const KeccakBuiltinRunner = @import("./builtins/builtin_runner/keccak.zig").KeccakBuiltinRunner;
const BitwiseInstanceDef = @import("./types/bitwise_instance_def.zig").BitwiseInstanceDef;
const KeccakInstanceDef = @import("./types/keccak_instance_def.zig").KeccakInstanceDef;
const Felt252 = @import("../math/fields/starknet.zig").Felt252;
const HashBuiltinRunner = @import("./builtins/builtin_runner/hash.zig").HashBuiltinRunner;
const Instruction = @import("instructions.zig").Instruction;
const CairoVM = @import("core.zig").CairoVM;
const computeRes = @import("core.zig").computeRes;
const OperandsResult = @import("core.zig").OperandsResult;
const deduceOp1 = @import("core.zig").deduceOp1;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;

test "CairoVM: deduceMemoryCell no builtin" {
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();
    try expectEqual(
        @as(?MaybeRelocatable, null),
        try vm.deduceMemoryCell(std.testing.allocator, Relocatable.init(
            0,
            0,
        )),
    );
}

test "CairoVM: deduceMemoryCell builtin valid" {
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();
    var instance_def: BitwiseInstanceDef = .{};
    try vm.builtin_runners.append(BuiltinRunner{ .Bitwise = BitwiseBuiltinRunner.init(
        &instance_def,
        true,
    ) });

    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 5 }, .{10} },
            .{ .{ 0, 6 }, .{12} },
            .{ .{ 0, 7 }, .{0} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);
    try expectEqual(
        MaybeRelocatable.fromU256(8),
        (try vm.deduceMemoryCell(std.testing.allocator, Relocatable.init(
            0,
            7,
        ))).?,
    );
}

test "update pc regular no imm" {
    // Test setup
    const allocator = std.testing.allocator;

    const operands = OperandsResult.default();
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updatePc(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .AP,
            .res_logic = .Add,
            .pc_update = .Regular,
            .ap_update = .Add,
            .fp_update = .Regular,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    const pc = vm.run_context.pc.*;
    try expectEqual(
        @as(
            u64,
            1,
        ),
        pc.offset,
    );
}

test "update pc regular with imm" {
    // Test setup
    const allocator = std.testing.allocator;
    const operands = OperandsResult.default();
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updatePc(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Regular,
            .ap_update = .Add,
            .fp_update = .Regular,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    const pc = vm.run_context.pc.*;
    try expectEqual(
        @as(
            u64,
            2,
        ),
        pc.offset,
    );
}

test "update pc jump with operands res null" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.res = null;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try expectError(
        error.ResUnconstrainedUsedWithPcUpdateJump,
        vm.updatePc(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .FP,
                .op_0_reg = .FP,
                .op_1_addr = .Imm,
                .res_logic = .Add,
                .pc_update = .Jump,
                .ap_update = .Add,
                .fp_update = .Regular,
                .opcode = .Call,
            },
            operands,
        ),
    );
}

test "update pc jump with operands res not relocatable" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.res = MaybeRelocatable.fromU64(0);
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try expectError(
        error.PcUpdateJumpResNotRelocatable,
        vm.updatePc(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .FP,
                .op_0_reg = .FP,
                .op_1_addr = .Imm,
                .res_logic = .Add,
                .pc_update = .Jump,
                .ap_update = .Add,
                .fp_update = .Regular,
                .opcode = .Call,
            },
            operands,
        ),
    );
}

test "update pc jump with operands res relocatable" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.res = MaybeRelocatable.fromRelocatable(Relocatable.init(
        0,
        42,
    ));
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updatePc(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Jump,
            .ap_update = .Add,
            .fp_update = .Regular,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    const pc = vm.run_context.pc.*;
    try expectEqual(
        @as(
            u64,
            42,
        ),
        pc.offset,
    );
}

test "update pc jump rel with operands res null" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.res = null;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try expectError(
        error.ResUnconstrainedUsedWithPcUpdateJumpRel,
        vm.updatePc(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .FP,
                .op_0_reg = .FP,
                .op_1_addr = .Imm,
                .res_logic = .Add,
                .pc_update = .JumpRel,
                .ap_update = .Add,
                .fp_update = .Regular,
                .opcode = .Call,
            },
            operands,
        ),
    );
}

test "update pc jump rel with operands res not felt" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.res = MaybeRelocatable.fromRelocatable(Relocatable.init(
        0,
        42,
    ));
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try expectError(
        error.PcUpdateJumpRelResNotFelt,
        vm.updatePc(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .FP,
                .op_0_reg = .FP,
                .op_1_addr = .Imm,
                .res_logic = .Add,
                .pc_update = .JumpRel,
                .ap_update = .Add,
                .fp_update = .Regular,
                .opcode = .Call,
            },
            operands,
        ),
    );
}

test "update pc jump rel with operands res felt" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.res = MaybeRelocatable.fromU64(42);
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updatePc(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .JumpRel,
            .ap_update = .Add,
            .fp_update = .Regular,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    const pc = vm.run_context.pc.*;
    try expectEqual(
        @as(
            u64,
            42,
        ),
        pc.offset,
    );
}

test "update pc update jnz with operands dst zero" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.dst = MaybeRelocatable.fromU64(0);
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updatePc(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Jnz,
            .ap_update = .Add,
            .fp_update = .Regular,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    const pc = vm.run_context.pc.*;
    try expectEqual(
        @as(
            u64,
            2,
        ),
        pc.offset,
    );
}

test "update pc update jnz with operands dst not zero op1 not felt" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.dst = MaybeRelocatable.fromU64(1);
    operands.op_1 = MaybeRelocatable.fromRelocatable(Relocatable.init(
        0,
        42,
    ));
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try expectError(
        error.TypeMismatchNotFelt,
        vm.updatePc(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .FP,
                .op_0_reg = .FP,
                .op_1_addr = .Imm,
                .res_logic = .Add,
                .pc_update = .Jnz,
                .ap_update = .Add,
                .fp_update = .Regular,
                .opcode = .Call,
            },
            operands,
        ),
    );
}

test "update pc update jnz with operands dst not zero op1 felt" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.dst = MaybeRelocatable.fromU64(1);
    operands.op_1 = MaybeRelocatable.fromU64(42);
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updatePc(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Jnz,
            .ap_update = .Add,
            .fp_update = .Regular,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    const pc = vm.run_context.pc.*;
    try expectEqual(
        @as(
            u64,
            42,
        ),
        pc.offset,
    );
}

test "CairoVM: updateAp using Add for AP update with null operands res" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.res = null; // Simulate unconstrained res
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try expectError(
        error.ApUpdateAddResUnconstrained,
        vm.updateAp(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .FP,
                .op_0_reg = .FP,
                .op_1_addr = .Imm,
                .res_logic = .Add,
                .pc_update = .Jump,
                .ap_update = .Add,
                .fp_update = .Regular,
                .opcode = .Call,
            },
            operands,
        ),
    );
}

test "CairoVM: updateAp using Add for AP update with non-null operands result" {
    // Create an allocator for testing purposes.
    const allocator = std.testing.allocator;
    // Initialize operands result with a non-null result value.
    var operands = OperandsResult.default();
    operands.res = MaybeRelocatable.fromU256(10);

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    // Ensure VM instance is deallocated after the test.
    defer vm.deinit();

    // Invoke the updateAp function with specified parameters.
    try vm.updateAp(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Jump,
            .ap_update = .Add,
            .fp_update = .Regular,
            .opcode = .Call,
        },
        operands,
    );

    // Expectation: The AP offset should be updated to the expected value after the operation.
    try expectEqual(
        @as(u64, 10),
        vm.run_context.ap.*.offset,
    );
}

test "CairoVM: updateAp using Add1 for AP update" {
    // Test setup
    const allocator = std.testing.allocator;
    const operands = OperandsResult.default();
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updateAp(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Jump,
            .ap_update = .Add1,
            .fp_update = .Regular,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    // Verify the AP offset was incremented by 1.
    const ap = vm.run_context.ap.*;
    try expectEqual(
        @as(
            u64,
            1,
        ),
        ap.offset,
    );
}

test "update ap add2" {
    // Test setup
    const allocator = std.testing.allocator;
    const operands = OperandsResult.default();
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updateAp(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Jump,
            .ap_update = .Add2,
            .fp_update = .Regular,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    // Verify the AP offset was incremented by 2.
    const ap = vm.run_context.ap.*;
    try expectEqual(
        @as(
            u64,
            2,
        ),
        ap.offset,
    );
}

test "update fp appplus2" {
    // Test setup
    const allocator = std.testing.allocator;
    const operands = OperandsResult.default();
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updateFp(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Jump,
            .ap_update = .Add,
            .fp_update = .APPlus2,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    // Verify the FP offset was incremented by 2.
    const fp = vm.run_context.fp.*;
    try expectEqual(
        @as(
            u64,
            2,
        ),
        fp.offset,
    );
}

test "update fp dst relocatable" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.dst = MaybeRelocatable.fromRelocatable(Relocatable.init(
        0,
        42,
    ));
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updateFp(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Jump,
            .ap_update = .Add,
            .fp_update = .Dst,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    // Verify the FP offset was incremented by 2.
    const fp = vm.run_context.fp.*;
    try expectEqual(
        @as(
            u64,
            42,
        ),
        fp.offset,
    );
}

test "update fp dst felt" {
    // Test setup
    const allocator = std.testing.allocator;
    var operands = OperandsResult.default();
    operands.dst = MaybeRelocatable.fromU64(42);
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    try vm.updateFp(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .Imm,
            .res_logic = .Add,
            .pc_update = .Jump,
            .ap_update = .Add,
            .fp_update = .Dst,
            .opcode = .Call,
        },
        operands,
    );

    // Test checks
    // Verify the FP offset was incremented by 2.
    const fp = vm.run_context.fp.*;
    try expectEqual(
        @as(
            u64,
            42,
        ),
        fp.offset,
    );
}

test "trace is enabled" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    const config = Config{ .proof_mode = false, .enable_trace = true };

    var vm = try CairoVM.init(
        allocator,
        config,
    );
    defer vm.deinit();

    // Test body
    // Do nothing

    // Test checks
    // Check that trace was initialized
    if (!vm.trace_context.isEnabled()) {
        return error.TraceShouldHaveBeenEnabled;
    }
}

test "trace is disabled" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test body
    // Do nothing

    // Test checks
    // Check that trace was initialized
    if (vm.trace_context.isEnabled()) {
        return error.TraceShouldHaveBeenDisabled;
    }
}

test "get relocate trace without relocating trace" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    const config = Config{ .proof_mode = false, .enable_trace = true };

    var vm = try CairoVM.init(
        allocator,
        config,
    );
    defer vm.deinit();
    try expectError(TraceError.TraceNotRelocated, vm.getRelocatedTrace());
}

test "CairoVM: relocateTrace should return Trace Error if trace_relocated already set to true" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(
        allocator,
        .{},
    );
    defer vm.deinit();

    // Set trace_relocated to true
    // Simulate the trace_relocated flag being already set to true.
    vm.trace_relocated = true;

    // Create a relocation table
    // Initialize an empty relocation table.
    var relocation_table = ArrayList(usize).init(std.testing.allocator);
    defer relocation_table.deinit();

    // Expect TraceError.AlreadyRelocated error
    // Assert that calling relocateTrace with trace_relocated already true results in an error.
    try expectError(
        TraceError.AlreadyRelocated,
        vm.relocateTrace(relocation_table.items),
    );
}

test "CairoVM: relocateTrace should return Trace Error if relocation_table len is less than 2" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(
        allocator,
        .{},
    );
    defer vm.deinit();

    // Create a relocation table
    // Initialize an empty relocation table.
    var relocation_table = ArrayList(usize).init(std.testing.allocator);
    defer relocation_table.deinit();

    // Expect TraceError.NoRelocationFound error
    // Assert that calling relocateTrace with a relocation_table length less than 2 results in an error.
    try expectError(
        TraceError.NoRelocationFound,
        vm.relocateTrace(relocation_table.items),
    );
}

test "CairoVM: relocateTrace should return Trace Error if trace context state is disabled" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(
        allocator,
        .{},
    );
    defer vm.deinit();

    // Create a relocation table
    // Initialize an empty relocation table and add specific values to it.
    var relocation_table = ArrayList(usize).init(std.testing.allocator);
    defer relocation_table.deinit();
    try relocation_table.append(1);
    try relocation_table.append(15);
    try relocation_table.append(27);
    try relocation_table.append(29);
    try relocation_table.append(29);

    // Expect TraceError.TraceNotEnabled error
    // Assert that calling relocateTrace when the trace context state is disabled results in an error.
    try expectError(
        TraceError.TraceNotEnabled,
        vm.relocateTrace(relocation_table.items),
    );
}

test "CairoVM: relocateTrace and trace comparison (simple use case)" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    const config = Config{ .proof_mode = false, .enable_trace = true };

    var vm = try CairoVM.init(
        allocator,
        config,
    );
    defer vm.deinit();
    const pc = Relocatable.init(0, 0);
    const ap = Relocatable.init(2, 0);
    const fp = Relocatable.init(2, 0);
    try vm.trace_context.traceInstruction(.{ .pc = pc, .ap = ap, .fp = fp });
    for (0..4) |_| {
        _ = try vm.segments.addSegment();
    }

    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{2345108766317314046} },
            .{ .{ 1, 0 }, .{ 2, 0 } },
            .{ .{ 1, 1 }, .{ 3, 0 } },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    _ = try vm.computeSegmentsEffectiveSizes(false);

    const relocation_table = try vm.segments.relocateSegments(allocator);
    defer allocator.free(relocation_table);
    try vm.relocateTrace(relocation_table);

    const relocated_trace = TraceContext.RelocatedTraceEntry{
        .pc = Felt252.fromInteger(1),
        .ap = Felt252.fromInteger(4),
        .fp = Felt252.fromInteger(4),
    };
    const expected_relocated_trace = [_]TraceContext.RelocatedTraceEntry{relocated_trace};
    const actual_relocated_trace = try vm.getRelocatedTrace();
    for (expected_relocated_trace, actual_relocated_trace) |expected_trace, actual_trace| {
        try expectEqual(expected_trace, actual_trace);
    }
}

test "CairoVM: relocateTrace and trace comparison (more complex use case)" {
    // ProgramJson used:
    // %builtins output

    // from starkware.cairo.common.serialize import serialize_word

    // func main{output_ptr: felt*}():
    //    let a = 1
    //    serialize_word(a)
    //    let b = 17 * a
    //    serialize_word(b)
    //    return()
    // end

    // Relocated Trace:
    // [TraceEntry(pc=5, ap=18, fp=18),
    // TraceEntry(pc=6, ap=19, fp=18),
    // TraceEntry(pc=8, ap=20, fp=18),
    // TraceEntry(pc=1, ap=22, fp=22),
    // TraceEntry(pc=2, ap=22, fp=22),
    // TraceEntry(pc=4, ap=23, fp=22),
    // TraceEntry(pc=10, ap=23, fp=18),

    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(
        allocator,
        .{ .proof_mode = false, .enable_trace = true },
    );
    defer vm.deinit();

    // Initial Trace Entries
    // Define and append initial trace entries to the VM trace context.
    // pc, ap, and fp values are initialized and appended in pairs.
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 4),
        .ap = Relocatable.init(1, 3),
        .fp = Relocatable.init(1, 3),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 5),
        .ap = Relocatable.init(1, 4),
        .fp = Relocatable.init(1, 3),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 7),
        .ap = Relocatable.init(1, 5),
        .fp = Relocatable.init(1, 3),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 0),
        .ap = Relocatable.init(1, 7),
        .fp = Relocatable.init(1, 7),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 1),
        .ap = Relocatable.init(1, 7),
        .fp = Relocatable.init(1, 7),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 3),
        .ap = Relocatable.init(1, 8),
        .fp = Relocatable.init(1, 7),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 9),
        .ap = Relocatable.init(1, 8),
        .fp = Relocatable.init(1, 3),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 11),
        .ap = Relocatable.init(1, 9),
        .fp = Relocatable.init(1, 3),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 0),
        .ap = Relocatable.init(1, 11),
        .fp = Relocatable.init(1, 11),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 1),
        .ap = Relocatable.init(1, 11),
        .fp = Relocatable.init(1, 11),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 3),
        .ap = Relocatable.init(1, 12),
        .fp = Relocatable.init(1, 11),
    });
    try vm.trace_context.state.enabled.entries.append(.{
        .pc = Relocatable.init(0, 13),
        .ap = Relocatable.init(1, 12),
        .fp = Relocatable.init(1, 3),
    });

    // Create a relocation table
    // Create a relocation table and append specific values to it.
    var relocation_table = ArrayList(usize).init(std.testing.allocator);
    defer relocation_table.deinit();

    try relocation_table.append(1);
    try relocation_table.append(15);
    try relocation_table.append(27);
    try relocation_table.append(29);
    try relocation_table.append(29);

    // Assert trace relocation status
    // Ensure the trace relocation status flag is set as expected (false).
    try expect(!vm.trace_relocated);

    try vm.relocateTrace(relocation_table.items);

    // Expected Relocated Entries
    // Define the expected relocated entries after the trace relocation process.
    var expected_relocated_entries = ArrayList(TraceContext.RelocatedTraceEntry).init(std.testing.allocator);
    defer expected_relocated_entries.deinit();

    // Append expected relocated entries using Felt252 values.
    // pc, ap, and fp values are appended in pairs similar to the initial entries.
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(5),
        .ap = Felt252.fromInteger(18),
        .fp = Felt252.fromInteger(18),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(6),
        .ap = Felt252.fromInteger(19),
        .fp = Felt252.fromInteger(18),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(8),
        .ap = Felt252.fromInteger(20),
        .fp = Felt252.fromInteger(18),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(1),
        .ap = Felt252.fromInteger(22),
        .fp = Felt252.fromInteger(22),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(2),
        .ap = Felt252.fromInteger(22),
        .fp = Felt252.fromInteger(22),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(4),
        .ap = Felt252.fromInteger(23),
        .fp = Felt252.fromInteger(22),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(10),
        .ap = Felt252.fromInteger(23),
        .fp = Felt252.fromInteger(18),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(12),
        .ap = Felt252.fromInteger(24),
        .fp = Felt252.fromInteger(18),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(1),
        .ap = Felt252.fromInteger(26),
        .fp = Felt252.fromInteger(26),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(2),
        .ap = Felt252.fromInteger(26),
        .fp = Felt252.fromInteger(26),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(4),
        .ap = Felt252.fromInteger(27),
        .fp = Felt252.fromInteger(26),
    });
    try expected_relocated_entries.append(.{
        .pc = Felt252.fromInteger(14),
        .ap = Felt252.fromInteger(27),
        .fp = Felt252.fromInteger(18),
    });

    // Assert relocated entries match the expected entries
    // Ensure the relocated trace entries in the VM match the expected relocated entries.
    try expectEqualSlices(
        TraceContext.RelocatedTraceEntry,
        expected_relocated_entries.items,
        vm.trace_context.state.enabled.relocated_trace_entries.items,
    );
    // Assert trace relocation status
    // Ensure the trace relocation status flag is set as expected (true).
    try expect(vm.trace_relocated);
}

// This instruction is used in the functions that test the `deduceOp1` function. Only the
// `opcode` and `res_logic` fields are usually changed.
const deduceOpTestInstr = Instruction{
    .off_0 = 1,
    .off_1 = 2,
    .off_2 = 3,
    .dst_reg = .FP,
    .op_0_reg = .AP,
    .op_1_addr = .AP,
    .res_logic = .Add,
    .pc_update = .Jump,
    .ap_update = .Regular,
    .fp_update = .Regular,
    .opcode = .Call,
};

test "deduceOp0 when opcode == .Call" {
    // Setup test context
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .Call;

    const deduceOp0 = try vm.deduceOp0(&instr, &null, &null);

    // Test checks
    const expected_op_0: ?MaybeRelocatable = MaybeRelocatable.fromRelocatable(Relocatable.init(0, 1)); // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = null;
    try expectEqual(expected_op_0, deduceOp0.op_0);
    try expectEqual(expected_res, deduceOp0.res);
}

test "deduceOp0 when opcode == .AssertEq, res_logic == .Add, input is felt" {
    // Setup test context
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Add;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(3);
    const op1: ?MaybeRelocatable = MaybeRelocatable.fromU64(2);

    const deduceOp0 = try vm.deduceOp0(&instr, &dst, &op1);

    // Test checks
    try expect(deduceOp0.op_0.?.eq(MaybeRelocatable.fromU64(1)));
    try expect(deduceOp0.res.?.eq(MaybeRelocatable.fromU64(3)));
}

test "deduceOp0 when opcode == .AssertEq, res_logic == .Add, with no input" {
    // Setup test context
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Add;

    const deduceOp0 = try vm.deduceOp0(&instr, &null, &null);

    // Test checks
    const expected_op_0: ?MaybeRelocatable = null; // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = null;
    try expectEqual(expected_op_0, deduceOp0.op_0);
    try expectEqual(expected_res, deduceOp0.res);
}

test "deduceOp0 when opcode == .AssertEq, res_logic == .Mul, input is felt 1" {
    // Setup test context
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Mul;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(4);
    const op1: ?MaybeRelocatable = MaybeRelocatable.fromU64(2);

    const deduceOp0 = try vm.deduceOp0(&instr, &dst, &op1);

    // Test checks
    const expected_op_0: ?MaybeRelocatable = MaybeRelocatable.fromU64(2); // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = MaybeRelocatable.fromU64(4);
    try expectEqual(expected_op_0, deduceOp0.op_0);
    try expectEqual(expected_res, deduceOp0.res);
}

test "deduceOp0 when opcode == .AssertEq, res_logic == .Op1, input is felt" {
    // Setup test context
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Op1;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(4);
    const op1: ?MaybeRelocatable = MaybeRelocatable.fromU64(0);

    const deduceOp0 = try vm.deduceOp0(&instr, &dst, &op1);

    // Test checks
    const expected_op_0: ?MaybeRelocatable = null; // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = null;
    try expectEqual(expected_op_0, deduceOp0.op_0);
    try expectEqual(expected_res, deduceOp0.res);
}

test "deduceOp0 when opcode == .AssertEq, res_logic == .Mul, input is felt 2" {
    // Setup test context
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Mul;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(4);
    const op1: ?MaybeRelocatable = MaybeRelocatable.fromU64(0);

    const deduceOp0 = try vm.deduceOp0(&instr, &dst, &op1);

    // Test checks
    const expected_op_0: ?MaybeRelocatable = null; // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = null;
    try expectEqual(expected_op_0, deduceOp0.op_0);
    try expectEqual(expected_res, deduceOp0.res);
}

test "deduceOp0 when opcode == .Ret, res_logic == .Mul, input is felt" {
    // Setup test context
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .Ret;
    instr.res_logic = .Mul;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(4);
    const op1: ?MaybeRelocatable = MaybeRelocatable.fromU64(0);

    const deduceOp0 = try vm.deduceOp0(&instr, &dst, &op1);

    // Test checks
    const expected_op_0: ?MaybeRelocatable = null; // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = null;
    try expectEqual(expected_op_0, deduceOp0.op_0);
    try expectEqual(expected_res, deduceOp0.res);
}

test "deduceOp1 when opcode == .Call" {
    // Setup test context
    // Nothing.

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .Call;

    const op1Deduction = try deduceOp1(&instr, &null, &null);

    // Test checks
    const expected_op_1: ?MaybeRelocatable = null; // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = null;
    try expectEqual(expected_op_1, op1Deduction.op_1);
    try expectEqual(expected_res, op1Deduction.res);
}

test "deduceOp1 when opcode == .AssertEq, res_logic == .Add, input is felt" {
    // Setup test context
    // Nothing.

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Add;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(3);
    const op0: ?MaybeRelocatable = MaybeRelocatable.fromU64(2);

    const op1Deduction = try deduceOp1(&instr, &dst, &op0);

    // Test checks
    try expect(op1Deduction.op_1.?.eq(MaybeRelocatable.fromU64(1)));
    try expect(op1Deduction.res.?.eq(MaybeRelocatable.fromU64(3)));
}

test "deduceOp1 when opcode == .AssertEq, res_logic == .Mul, non-zero op0" {
    // Setup test context
    // Nothing.

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Mul;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(4);
    const op0: ?MaybeRelocatable = MaybeRelocatable.fromU64(2);

    const op1Deduction = try deduceOp1(&instr, &dst, &op0);

    // Test checks
    try expect(op1Deduction.op_1.?.eq(MaybeRelocatable.fromU64(2)));
    try expect(op1Deduction.res.?.eq(MaybeRelocatable.fromU64(4)));
}

test "deduceOp1 when opcode == .AssertEq, res_logic == .Mul, zero op0" {
    // Setup test context
    // Nothing.

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Mul;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(4);
    const op0: ?MaybeRelocatable = MaybeRelocatable.fromU64(0);

    const op1Deduction = try deduceOp1(&instr, &dst, &op0);

    // Test checks
    const expected_op_1: ?MaybeRelocatable = null; // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = null;
    try expectEqual(expected_op_1, op1Deduction.op_1);
    try expectEqual(expected_res, op1Deduction.res);
}

test "deduceOp1 when opcode == .AssertEq, res_logic = .Mul, no input" {
    // Setup test context
    // Nothing.

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Mul;

    const op1Deduction = try deduceOp1(&instr, &null, &null);

    // Test checks
    const expected_op_1: ?MaybeRelocatable = null; // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = null;
    try expectEqual(expected_op_1, op1Deduction.op_1);
    try expectEqual(expected_res, op1Deduction.res);
}

test "deduceOp1 when opcode == .AssertEq, res_logic == .Op1, no dst" {
    // Setup test context
    // Nothing.

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Op1;

    const op0: ?MaybeRelocatable = MaybeRelocatable.fromU64(0);

    const op1Deduction = try deduceOp1(&instr, &null, &op0);

    // Test checks
    const expected_op_1: ?MaybeRelocatable = null; // temp var needed for type inference
    const expected_res: ?MaybeRelocatable = null;
    try expectEqual(expected_op_1, op1Deduction.op_1);
    try expectEqual(expected_res, op1Deduction.res);
}

test "deduceOp1 when opcode == .AssertEq, res_logic == .Op1, no op0" {
    // Setup test context
    // Nothing/

    // Test body
    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Op1;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(7);

    const op1Deduction = try deduceOp1(&instr, &dst, &null);

    // Test checks
    try expect(op1Deduction.op_1.?.eq(MaybeRelocatable.fromU64(7)));
    try expect(op1Deduction.res.?.eq(MaybeRelocatable.fromU64(7)));
}

test "set get value in vm memory" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    const address = Relocatable.init(1, 0);
    const value = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(42));

    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 1, 0 }, .{42} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Test checks
    // Verify the value is correctly set to 42.
    const actual_value = vm.segments.memory.get(address);
    const expected_value = value;
    try expectEqual(
        expected_value,
        actual_value.?,
    );
}

test "compute res op1 works" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);
    // Test body

    const value_op0 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(2));
    const value_op1 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(3));

    // Call with Op1 res logic
    const actual_res = try computeRes(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .AP,
            .op_0_reg = .AP,
            .op_1_addr = .AP,
            .res_logic = .Op1,
            .pc_update = .Regular,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
        value_op0,
        value_op1,
    );
    const expected_res = value_op1;

    // Test checks
    try expectEqual(
        expected_res,
        actual_res.?,
    );
}

test "compute res add felts works" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);
    // Test body

    const value_op0 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(2));
    const value_op1 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(3));

    const actual_res = try computeRes(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .AP,
            .op_0_reg = .AP,
            .op_1_addr = .AP,
            .res_logic = .Add,
            .pc_update = .Regular,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
        value_op0,
        value_op1,
    );
    const expected_res = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(5));

    // Test checks
    try expectEqual(
        expected_res,
        actual_res.?,
    );
}

test "compute res add felt to offset works" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);
    // Test body

    const value_op0 = Relocatable.init(1, 1);
    const op0 = MaybeRelocatable.fromRelocatable(value_op0);

    const op1 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(3));

    const actual_res = try computeRes(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .AP,
            .op_0_reg = .AP,
            .op_1_addr = .AP,
            .res_logic = .Add,
            .pc_update = .Regular,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
        op0,
        op1,
    );
    const res = Relocatable.init(1, 4);
    const expected_res = MaybeRelocatable.fromRelocatable(res);

    // Test checks
    try expectEqual(
        expected_res,
        actual_res.?,
    );
}

test "compute res add fails two relocs" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);
    // Test body

    const value_op0 = Relocatable.init(1, 0);
    const value_op1 = Relocatable.init(1, 1);

    const op0 = MaybeRelocatable.fromRelocatable(value_op0);
    const op1 = MaybeRelocatable.fromRelocatable(value_op1);

    // Test checks
    try expectError(
        MathError.RelocatableAdd,
        computeRes(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .NOp,
            },
            op0,
            op1,
        ),
    );
}

test "compute res mul works" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);
    // Test body

    const value_op0 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(2));
    const value_op1 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(3));

    // Call with Mul res logic
    const actual_res = try computeRes(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .AP,
            .op_0_reg = .AP,
            .op_1_addr = .AP,
            .res_logic = .Mul,
            .pc_update = .Regular,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
        value_op0,
        value_op1,
    );
    const expected_res = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(6));

    // Test checks
    try expectEqual(
        expected_res,
        actual_res.?,
    );
}

test "compute res mul fails two relocs" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);
    // Test body

    const value_op0 = Relocatable.init(1, 0);
    const value_op1 = Relocatable.init(1, 1);

    const op0 = MaybeRelocatable.fromRelocatable(value_op0);
    const op1 = MaybeRelocatable.fromRelocatable(value_op1);

    // Test checks
    try expectError(
        MathError.RelocatableMul,
        computeRes(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Mul,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .NOp,
            },
            op0,
            op1,
        ),
    );
}

test "compute res mul fails felt and reloc" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();
    // Test body

    const value_op0 = Relocatable.init(1, 0);
    const op0 = MaybeRelocatable.fromRelocatable(value_op0);
    const op1 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(2));

    // Test checks
    try expectError(
        MathError.RelocatableMul,
        computeRes(&.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .AP,
            .op_0_reg = .AP,
            .op_1_addr = .AP,
            .res_logic = .Mul,
            .pc_update = .Regular,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        }, op0, op1),
    );
}

test "compute res Unconstrained should return null" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);
    // Test body

    const value_op0 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(2));
    const value_op1 = MaybeRelocatable.fromFelt(starknet_felt.Felt252.fromInteger(3));

    // Call with unconstrained res logic
    const actual_res = try computeRes(
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .AP,
            .op_0_reg = .AP,
            .op_1_addr = .AP,
            .res_logic = .Unconstrained,
            .pc_update = .Regular,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
        value_op0,
        value_op1,
    );
    const expected_res: ?MaybeRelocatable = null;

    // Test checks
    try expectEqual(
        expected_res,
        actual_res,
    );
}

test "CairoVM: compute operands add AP" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);

    // Test body
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 1, 0 }, .{5} },
            .{ .{ 1, 1 }, .{2} },
            .{ .{ 1, 2 }, .{3} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    const expected_operands: OperandsResult = .{
        .dst_addr = .{ .segment_index = 1, .offset = 0 },
        .op_0_addr = .{ .segment_index = 1, .offset = 1 },
        .op_1_addr = .{ .segment_index = 1, .offset = 2 },
        .dst = .{ .felt = Felt252.fromInteger(5) },
        .op_0 = .{ .felt = Felt252.fromInteger(2) },
        .op_1 = .{ .felt = Felt252.fromInteger(3) },
        .res = .{ .felt = Felt252.fromInteger(5) },
        .deduced_operands = 0,
    };

    const actual_operands = try vm.computeOperands(
        std.testing.allocator,
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .AP,
            .op_0_reg = .AP,
            .op_1_addr = .AP,
            .res_logic = .Add,
            .pc_update = .Regular,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
    );

    // Test checks
    try expectEqual(
        expected_operands,
        actual_operands,
    );
}

test "CairoVM: compute operands mul FP" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.fp.* = Relocatable.init(1, 0);

    // Test body
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 1, 0 }, .{6} },
            .{ .{ 1, 1 }, .{2} },
            .{ .{ 1, 2 }, .{3} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    const expected_operands: OperandsResult = .{
        .dst_addr = .{ .segment_index = 1, .offset = 0 },
        .op_0_addr = .{ .segment_index = 1, .offset = 1 },
        .op_1_addr = .{ .segment_index = 1, .offset = 2 },
        .dst = .{ .felt = Felt252.fromInteger(6) },
        .op_0 = .{ .felt = Felt252.fromInteger(2) },
        .op_1 = .{ .felt = Felt252.fromInteger(3) },
        .res = .{ .felt = Felt252.fromInteger(6) },
        .deduced_operands = 0,
    };

    const actual_operands = try vm.computeOperands(
        std.testing.allocator,
        &.{
            .off_0 = 0,
            .off_1 = 1,
            .off_2 = 2,
            .dst_reg = .FP,
            .op_0_reg = .FP,
            .op_1_addr = .FP,
            .res_logic = .Mul,
            .pc_update = .Regular,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
    );

    // Test checks
    try expectEqual(
        expected_operands,
        actual_operands,
    );
}

test "CairoVM: compute operands JNZ" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);

    // Test body
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{0x206800180018001} },
            .{ .{ 1, 1 }, .{0x4} },
            .{ .{ 0, 1 }, .{0x4} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    const expected_operands: OperandsResult = .{
        .dst_addr = .{ .segment_index = 1, .offset = 1 },
        .op_0_addr = .{ .segment_index = 1, .offset = 1 },
        .op_1_addr = .{ .segment_index = 0, .offset = 1 },
        .dst = .{ .felt = Felt252.fromInteger(4) },
        .op_0 = .{ .felt = Felt252.fromInteger(4) },
        .op_1 = .{ .felt = Felt252.fromInteger(4) },
        .res = null,
        .deduced_operands = 0,
    };

    const actual_operands = try vm.computeOperands(
        std.testing.allocator,
        &.{
            .off_0 = 1,
            .off_1 = 1,
            .off_2 = 1,
            .dst_reg = .AP,
            .op_0_reg = .AP,
            .op_1_addr = .Imm,
            .res_logic = .Unconstrained,
            .pc_update = .Jnz,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
    );

    // Test checks
    try expectEqual(
        expected_operands,
        actual_operands,
    );
}

test "CairoVM: compute operands deduce dst none" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);

    // Test body
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{.{ .{ 1, 0 }, .{145944781867024385} }},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Test checks
    try expectError(
        CairoVMError.NoDst,
        vm.computeOperands(
            std.testing.allocator,
            &.{
                .off_0 = 2,
                .off_1 = 0,
                .off_2 = 0,
                .dst_reg = .FP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Unconstrained,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .NOp,
            },
        ),
    );
}

test "CairoVM: compute operands with op_1_addr as Op0" {
    // Test setup
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.run_context.ap.* = Relocatable.init(1, 0);

    // Test body
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{0x206800180018001} },
            .{ .{ 1, 1 }, .{ 1, 4 } },
            .{ .{ 1, 5 }, .{ 1, 2 } },
            .{ .{ 0, 1 }, .{0x4} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    const expected_operands: OperandsResult = .{
        .dst_addr = .{ .segment_index = 1, .offset = 1 },
        .op_0_addr = .{ .segment_index = 1, .offset = 1 },
        .op_1_addr = .{ .segment_index = 1, .offset = 5 },
        .dst = .{ .relocatable = .{ .segment_index = 1, .offset = 4 } },
        .op_0 = .{ .relocatable = .{ .segment_index = 1, .offset = 4 } },
        .op_1 = .{ .relocatable = .{ .segment_index = 1, .offset = 2 } },
        .res = null,
        .deduced_operands = 0,
    };

    const actual_operands = try vm.computeOperands(
        std.testing.allocator,
        &.{
            .off_0 = 1,
            .off_1 = 1,
            .off_2 = 1,
            .dst_reg = .AP,
            .op_0_reg = .AP,
            .op_1_addr = .Op0,
            .res_logic = .Unconstrained,
            .pc_update = .Jnz,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
    );

    // Test checks
    try expectEqual(
        expected_operands,
        actual_operands,
    );
}

test "memory is not leaked upon allocation failure during initialization" {
    var i: usize = 0;
    while (i < 20) {
        // ************************************************************
        // *                 SETUP TEST CONTEXT                       *
        // ************************************************************
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        i += 1;

        //         // ************************************************************
        //         // *                      TEST BODY                           *
        //         // ************************************************************
        //         // Nothing.

        //         // ************************************************************
        //         // *                      TEST CHECKS                         *
        //         // ************************************************************
        //         // Error must have occured!

        //         // It's not given that the final error will be an OutOfMemory. It's likely though.
        //         // Plus we're not certain that the error will be thrown at the same place as the
        //         // VM is upgraded. For this reason, we should just ensure that no memory has
        //         // been leaked.
        //         // try expectError(error.OutOfMemory, CairoVM.init(allocator.allocator(), .{}));

        // Note that `.deinit()` is not called in case of failure (obviously).
        // If error handling is done correctly, no memory should be leaked.
        var vm = CairoVM.init(allocator.allocator(), .{}) catch continue;
        vm.deinit();
    }
}

test "updateRegisters all regular" {
    // Test setup
    const operands = OperandsResult{
        .dst = .{ .felt = Felt252.fromInteger(11) },
        .res = .{ .felt = Felt252.fromInteger(8) },
        .op_0 = .{ .felt = Felt252.fromInteger(9) },
        .op_1 = .{ .felt = Felt252.fromInteger(10) },
        .dst_addr = .{},
        .op_0_addr = .{},
        .op_1_addr = .{},
        .deduced_operands = 0,
    };

    // Create a new VM instance.
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();
    vm.run_context.pc.* = Relocatable.init(0, 4);
    vm.run_context.ap.* = Relocatable.init(0, 5);
    vm.run_context.fp.* = Relocatable.init(0, 6);

    // Test body
    try vm.updateRegisters(
        &.{
            .off_0 = 1,
            .off_1 = 2,
            .off_2 = 3,
            .dst_reg = .FP,
            .op_0_reg = .AP,
            .op_1_addr = .AP,
            .res_logic = .Add,
            .pc_update = .Regular,
            .ap_update = .Regular,
            .fp_update = .Regular,
            .opcode = .NOp,
        },
        operands,
    );

    // Test checks
    // Verify the PC offset was incremented by 5.
    try expectEqual(
        Relocatable.init(0, 5),
        vm.run_context.pc.*,
    );

    // Verify the AP offset was incremented by 5.
    try expectEqual(
        Relocatable.init(0, 5),
        vm.run_context.ap.*,
    );

    // Verify the FP offset was incremented by 6.
    try expectEqual(
        Relocatable.init(0, 6),
        vm.run_context.fp.*,
    );
}

test "updateRegisters with mixed types" {
    // Test setup

    var instruction = deduceOpTestInstr;
    instruction.pc_update = .JumpRel;
    instruction.ap_update = .Add2;
    instruction.fp_update = .Dst;

    const operands = OperandsResult{
        .dst = .{ .relocatable = Relocatable.init(
            1,
            11,
        ) },
        .res = .{ .felt = Felt252.fromInteger(8) },
        .op_0 = .{ .felt = Felt252.fromInteger(9) },
        .op_1 = .{ .felt = Felt252.fromInteger(10) },
        .dst_addr = .{},
        .op_0_addr = .{},
        .op_1_addr = .{},
        .deduced_operands = 0,
    };

    // Create a new VM instance.
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();
    vm.run_context.pc.* = Relocatable.init(0, 4);
    vm.run_context.ap.* = Relocatable.init(0, 5);
    vm.run_context.fp.* = Relocatable.init(0, 6);

    // Test body
    try vm.updateRegisters(
        &instruction,
        operands,
    );

    // Test checks
    // Verify the PC offset was incremented by 12.
    try expectEqual(
        Relocatable.init(0, 12),
        vm.run_context.pc.*,
    );

    // Verify the AP offset was incremented by 7.
    try expectEqual(
        Relocatable.init(0, 7),
        vm.run_context.ap.*,
    );

    // Verify the FP offset was incremented by 11.
    try expectEqual(
        Relocatable.init(1, 11),
        vm.run_context.fp.*,
    );
}

test "CairoVM: computeOp0Deductions should return op0 from deduceOp0 if deduceMemoryCell is null" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    var instr = deduceOpTestInstr;
    instr.opcode = .Call;

    // Test check
    try expectEqual(
        MaybeRelocatable.fromSegment(0, 1),
        try vm.computeOp0Deductions(
            std.testing.allocator,
            Relocatable.init(0, 7),
            &instr,
            &null,
            &null,
        ),
    );
}

test "CairoVM: computeOp0Deductions with a valid built in and non null deduceMemoryCell should return deduceMemoryCell" {
    // Test setup
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();
    var instance_def: BitwiseInstanceDef = .{};
    try vm.builtin_runners.append(BuiltinRunner{ .Bitwise = BitwiseBuiltinRunner.init(
        &instance_def,
        true,
    ) });
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 5 }, .{10} },
            .{ .{ 0, 6 }, .{12} },
            .{ .{ 0, 7 }, .{0} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Test check
    try expectEqual(
        MaybeRelocatable.fromU256(8),
        try vm.computeOp0Deductions(
            std.testing.allocator,
            Relocatable.init(0, 7),
            &deduceOpTestInstr,
            &.{ .relocatable = .{} },
            &.{ .relocatable = .{} },
        ),
    );
}

test "CairoVM: computeOp0Deductions should return VM error if deduceOp0 and deduceMemoryCell are null" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    var instr = deduceOpTestInstr;
    instr.opcode = .Ret;
    instr.res_logic = .Mul;

    // Test check
    try expectError(
        CairoVMError.FailedToComputeOp0,
        vm.computeOp0Deductions(
            std.testing.allocator,
            Relocatable.init(0, 7),
            &instr,
            &MaybeRelocatable.fromU64(4),
            &MaybeRelocatable.fromU64(0),
        ),
    );
}

test "CairoVM: computeSegmentsEffectiveSizes should return the computed effective size for the VM segments" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{1} },
            .{ .{ 0, 1 }, .{1} },
            .{ .{ 0, 2 }, .{1} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    var actual = try vm.computeSegmentsEffectiveSizes(false);

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 3), actual.get(0).?);
}

test "CairoVM: deduceDst should return res if AssertEq opcode" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    const res = MaybeRelocatable.fromU256(7);

    // Test check
    try expectEqual(
        MaybeRelocatable.fromU256(7),
        try vm.deduceDst(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .AssertEq,
            },
            res,
        ),
    );
}

test "CairoVM: deduceDst should return VM error No dst if AssertEq opcode without res" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test check
    try expectError(
        CairoVMError.NoDst,
        vm.deduceDst(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .AssertEq,
            },
            null,
        ),
    );
}

test "CairoVM: deduceDst should return fp Relocatable if Call opcode" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();
    vm.run_context.fp.* = Relocatable.init(3, 23);

    // Test check
    try expectEqual(
        MaybeRelocatable.fromSegment(3, 23),
        try vm.deduceDst(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .Call,
            },
            null,
        ),
    );
}

test "CairoVM: deduceDst should return VM error No dst if not AssertEq or Call opcode" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test check
    try expectError(
        CairoVMError.NoDst,
        vm.deduceDst(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .Ret,
            },
            null,
        ),
    );
}

test "CairoVM: addMemorySegment should return a proper relocatable address for the new segment." {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test check
    try expectEqual(
        Relocatable.init(0, 0),
        try vm.addMemorySegment(),
    );
}

test "CairoVM: addMemorySegment should increase by one the number of segments in the VM" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    _ = try vm.addMemorySegment();
    _ = try vm.addMemorySegment();
    _ = try vm.addMemorySegment();

    // Test check
    try expectEqual(
        @as(u32, 3),
        vm.segments.memory.num_segments,
    );
}

test "CairoVM: getRelocatable without value raises error" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    // Test check
    try expectEqual(
        @as(?MaybeRelocatable, null),
        vm.getRelocatable(Relocatable.init(0, 0)),
    );
}

test "CairoVM: getRelocatable with value should return a MaybeRelocatable" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 34, 12 }, .{5} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Test check
    try expectEqual(
        MaybeRelocatable.fromU256(5),
        (vm.getRelocatable(Relocatable.init(34, 12))).?,
    );
}

test "CairoVM: getBuiltinRunners should return a reference to the builtin runners ArrayList" {
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();
    var instance_def: BitwiseInstanceDef = .{ .ratio = null, .total_n_bits = 2 };
    try vm.builtin_runners.append(BuiltinRunner{ .Bitwise = BitwiseBuiltinRunner.init(
        &instance_def,
        true,
    ) });

    // Test check
    try expectEqual(&vm.builtin_runners, vm.getBuiltinRunners());

    var expected = ArrayList(BuiltinRunner).init(std.testing.allocator);
    defer expected.deinit();
    try expected.append(BuiltinRunner{ .Bitwise = BitwiseBuiltinRunner.init(
        &instance_def,
        true,
    ) });
    try expectEqualSlices(
        BuiltinRunner,
        expected.items,
        vm.getBuiltinRunners().*.items,
    );
}

test "CairoVM: getSegmentUsedSize should return the size of a memory segment by its index if available" {
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();

    try vm.segments.segment_used_sizes.put(10, 4);
    try expectEqual(
        @as(u32, @intCast(4)),
        vm.getSegmentUsedSize(10).?,
    );
}

test "CairoVM: getSegmentUsedSize should return the size of the segment if contained in segment_sizes" {
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();

    try vm.segments.segment_sizes.put(10, 105);
    try expectEqual(@as(u32, 105), vm.getSegmentSize(10).?);
}

test "CairoVM: getSegmentSize should return the size of the segment via getSegmentUsedSize if not contained in segment_sizes" {
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();

    try vm.segments.segment_used_sizes.put(3, 6);
    try expectEqual(@as(u32, 6), vm.getSegmentSize(3).?);
}

test "CairoVM: getFelt should return UnknownMemoryCell error if no value at the given address" {
    // Test setup
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();

    // Test checks
    try expectError(
        error.UnknownMemoryCell,
        vm.getFelt(Relocatable.init(10, 30)),
    );
}

test "CairoVM: getFelt should return Felt252 if available at the given address" {
    // Test setup
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();

    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 10, 30 }, .{23} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Test checks
    try expectEqual(
        Felt252.fromInteger(23),
        try vm.getFelt(Relocatable.init(10, 30)),
    );
}

test "CairoVM: getFelt should return ExpectedInteger error if Relocatable instead of Felt at the given address" {
    // Test setup
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();

    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 10, 30 }, .{ 3, 7 } },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Test checks
    try expectError(
        error.ExpectedInteger,
        vm.getFelt(Relocatable.init(10, 30)),
    );
}

test "CairoVM: computeOp1Deductions should return op1 from deduceMemoryCell if not null" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    var instance_def: BitwiseInstanceDef = .{};
    try vm.builtin_runners.append(BuiltinRunner{ .Bitwise = BitwiseBuiltinRunner.init(
        &instance_def,
        true,
    ) });
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 0, 5 }, .{10} },
            .{ .{ 0, 6 }, .{12} },
            .{ .{ 0, 7 }, .{0} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    var instr = deduceOpTestInstr;
    var res: ?MaybeRelocatable = null;

    // Test check
    try expectEqual(
        MaybeRelocatable.fromU256(8),
        try vm.computeOp1Deductions(
            std.testing.allocator,
            Relocatable.init(0, 7),
            &res,
            &instr,
            &null,
            &null,
        ),
    );
}

test "CairoVM: computeOp1Deductions should return op1 from deduceOp1 if deduceMemoryCell is null" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Op1;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(7);
    var res: ?MaybeRelocatable = MaybeRelocatable.fromU64(7);

    // Test check
    try expectEqual(
        MaybeRelocatable.fromU64(7),
        try vm.computeOp1Deductions(
            std.testing.allocator,
            Relocatable.init(0, 7),
            &res,
            &instr,
            &dst,
            &null,
        ),
    );
}

test "CairoVM: computeOp1Deductions should modify res (if null) using res from deduceOp1 if deduceMemoryCell is null" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Op1;

    const dst: ?MaybeRelocatable = MaybeRelocatable.fromU64(7);
    var res: ?MaybeRelocatable = null;

    _ = try vm.computeOp1Deductions(
        std.testing.allocator,
        Relocatable.init(0, 7),
        &res,
        &instr,
        &dst,
        &null,
    );

    // Test check
    try expectEqual(
        MaybeRelocatable.fromU64(7),
        res.?,
    );
}

test "CairoVM: computeOp1Deductions should return CairoVMError error if deduceMemoryCell is null and deduceOp1.op_1 is null" {
    // Test setup
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    var instr = deduceOpTestInstr;
    instr.opcode = .AssertEq;
    instr.res_logic = .Op1;

    const op0: ?MaybeRelocatable = MaybeRelocatable.fromU64(0);
    var res: ?MaybeRelocatable = null;

    // Test check
    try expectError(
        CairoVMError.FailedToComputeOp1,
        vm.computeOp1Deductions(
            std.testing.allocator,
            Relocatable.init(0, 7),
            &res,
            &instr,
            &null,
            &op0,
        ),
    );
}

test "CairoVM: core utility function for testing test" {
    const allocator = std.testing.allocator;

    var cairo_vm = try CairoVM.init(allocator, .{});
    defer cairo_vm.deinit();

    try segments.segmentsUtil(
        cairo_vm.segments,
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{1} },
            .{ .{ 0, 1 }, .{1} },
            .{ .{ 0, 2 }, .{1} },
        },
    );
    defer cairo_vm.segments.memory.deinitData(std.testing.allocator);

    var actual = try cairo_vm.computeSegmentsEffectiveSizes(false);

    try expectEqual(@as(usize, 1), actual.count());
    try expectEqual(@as(u32, 3), actual.get(0).?);
}

test "CairoVM: OperandsResult set " {
    // Test setup
    var operands = OperandsResult.default();
    operands.setDst(true);

    // Test body
    try expectEqual(operands.deduced_operands, 1);
}

test "CairoVM: OperandsResult set Op1" {
    // Test setup
    var operands = OperandsResult.default();
    operands.setOp0(true);
    operands.setOp1(true);
    operands.setDst(true);

    // Test body
    try expectEqual(operands.deduced_operands, 7);
}

test "CairoVM: OperandsResult deduced set and was functionality" {
    // Test setup
    var operands = OperandsResult.default();
    operands.setOp1(true);

    // Test body
    try expect(operands.wasOp1Deducted());
}

test "CairoVM: InserDeducedOperands should insert operands if set as deduced" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    _ = try vm.addMemorySegment();
    _ = try vm.addMemorySegment();

    // Test body

    const dst_addr = Relocatable.init(1, 0);
    const dst_val = MaybeRelocatable{ .felt = Felt252.fromInteger(6) };

    const op0_addr = Relocatable.init(1, 1);
    const op0_val = MaybeRelocatable{ .felt = Felt252.fromInteger(2) };

    const op1_addr = Relocatable.init(1, 2);
    const op1_val = MaybeRelocatable{ .felt = Felt252.fromInteger(3) };
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    var test_operands = OperandsResult.default();
    test_operands.dst_addr = dst_addr;
    test_operands.op_0_addr = op0_addr;
    test_operands.op_1_addr = op1_addr;
    test_operands.dst = dst_val;
    test_operands.op_0 = op0_val;
    test_operands.op_1 = op1_val;
    test_operands.res = dst_val;
    test_operands.deduced_operands = 7;

    try vm.insertDeducedOperands(allocator, test_operands);

    // Test checks
    try expectEqual(
        vm.segments.memory.get(Relocatable.init(1, 0)),
        dst_val,
    );
    try expectEqual(
        vm.segments.memory.get(Relocatable.init(1, 1)),
        op0_val,
    );
    try expectEqual(
        vm.segments.memory.get(Relocatable.init(1, 2)),
        op1_val,
    );
}

test "CairoVM: InserDeducedOperands insert operands should not be inserted if not set as deduced" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    _ = try vm.addMemorySegment();
    _ = try vm.addMemorySegment();

    // Test body

    const dst_addr = Relocatable.init(1, 0);
    const dst_val = MaybeRelocatable{ .felt = Felt252.fromInteger(6) };

    const op0_addr = Relocatable.init(1, 1);
    const op0_val = MaybeRelocatable{ .felt = Felt252.fromInteger(2) };

    const op1_addr = Relocatable.init(1, 2);
    const op1_val = MaybeRelocatable{ .felt = Felt252.fromInteger(3) };
    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{},
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    var test_operands = OperandsResult.default();
    test_operands.dst_addr = dst_addr;
    test_operands.op_0_addr = op0_addr;
    test_operands.op_1_addr = op1_addr;
    test_operands.dst = dst_val;
    test_operands.op_0 = op0_val;
    test_operands.op_1 = op1_val;
    test_operands.res = dst_val;
    // 0 means no operands should be inserted
    test_operands.deduced_operands = 0;

    try vm.insertDeducedOperands(allocator, test_operands);

    // Test checks
    try expectEqual(
        @as(?MaybeRelocatable, null),
        vm.segments.memory.get(Relocatable.init(1, 0)),
    );
    try expectEqual(
        @as(?MaybeRelocatable, null),
        vm.segments.memory.get(Relocatable.init(1, 1)),
    );
    try expectEqual(
        @as(?MaybeRelocatable, null),
        vm.segments.memory.get(Relocatable.init(1, 2)),
    );
}

test "CairoVM: markAddressRangeAsAccessed should mark memory segments as accessed" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.is_run_finished = true;
    try segments.segmentsUtil(
        vm.segments,
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{0} },
            .{ .{ 0, 1 }, .{0} },
            .{ .{ 0, 2 }, .{1} },
            .{ .{ 0, 10 }, .{10} },
            .{ .{ 1, 1 }, .{1} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    try vm.markAddressRangeAsAccessed(Relocatable.init(0, 0), 3);
    try vm.markAddressRangeAsAccessed(Relocatable.init(0, 10), 2);
    try vm.markAddressRangeAsAccessed(Relocatable.init(1, 1), 1);

    try expect(vm.segments.memory.data.items[0].items[0].?.is_accessed);
    try expect(vm.segments.memory.data.items[0].items[1].?.is_accessed);
    try expect(vm.segments.memory.data.items[0].items[2].?.is_accessed);
    try expect(vm.segments.memory.data.items[0].items[10].?.is_accessed);
    try expect(vm.segments.memory.data.items[1].items[1].?.is_accessed);
    try expectEqual(
        @as(?usize, 4),
        vm.segments.memory.countAccessedAddressesInSegment(0),
    );
    try expectEqual(
        @as(?usize, 1),
        vm.segments.memory.countAccessedAddressesInSegment(1),
    );
}

test "CairoVM: markAddressRangeAsAccessed should return an error if the run is not finished" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    try expectError(
        CairoVMError.RunNotFinished,
        vm.markAddressRangeAsAccessed(Relocatable.init(0, 0), 3),
    );
}

test "CairoVM: opcodeAssertions should throw UnconstrainedAssertEq error" {
    const operands = OperandsResult{
        .dst = .{ .felt = Felt252.fromInteger(8) },
        .res = null,
        .op_0 = .{ .felt = Felt252.fromInteger(9) },
        .op_1 = .{ .felt = Felt252.fromInteger(10) },
        .dst_addr = .{},
        .op_0_addr = .{},
        .op_1_addr = .{},
        .deduced_operands = 0,
    };

    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    try expectError(
        CairoVMError.UnconstrainedResAssertEq,
        vm.opcodeAssertions(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .AssertEq,
            },
            operands,
        ),
    );
}

test "CairoVM: opcodeAssertions instructions failed - should throw DiffAssertValues error" {
    const operands = OperandsResult{
        .dst = MaybeRelocatable.fromU64(9),
        .res = MaybeRelocatable.fromU64(8),
        .op_0 = MaybeRelocatable.fromU64(9),
        .op_1 = MaybeRelocatable.fromU64(10),
        .dst_addr = .{},
        .op_0_addr = .{},
        .op_1_addr = .{},
        .deduced_operands = 0,
    };

    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    try expectError(
        CairoVMError.DiffAssertValues,
        vm.opcodeAssertions(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .AssertEq,
            },
            operands,
        ),
    );
}

test "CairoVM: opcodeAssertions instructions failed relocatables - should throw DiffAssertValues error" {
    const operands = OperandsResult{
        .dst = MaybeRelocatable.fromSegment(1, 1),
        .res = MaybeRelocatable.fromSegment(1, 2),
        .op_0 = MaybeRelocatable.fromU64(9),
        .op_1 = MaybeRelocatable.fromU64(10),
        .dst_addr = .{},
        .op_0_addr = .{},
        .op_1_addr = .{},
        .deduced_operands = 0,
    };

    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    try expectError(
        CairoVMError.DiffAssertValues,
        vm.opcodeAssertions(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .AssertEq,
            },
            operands,
        ),
    );
}

test "CairoVM: opcodeAssertions inconsistent op0 - should throw CantWriteReturnPC error" {
    const operands = OperandsResult{
        .dst = MaybeRelocatable.fromSegment(0, 1),
        .res = MaybeRelocatable.fromU64(8),
        .op_0 = MaybeRelocatable.fromU64(9),
        .op_1 = MaybeRelocatable.fromU64(10),
        .dst_addr = .{},
        .op_0_addr = .{},
        .op_1_addr = .{},
        .deduced_operands = 0,
    };

    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    vm.run_context.pc.* = Relocatable.init(0, 4);

    try expectError(
        CairoVMError.CantWriteReturnPc,
        vm.opcodeAssertions(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .Call,
            },
            operands,
        ),
    );
}

test "CairoVM: opcodeAssertions inconsistent dst - should throw CantWriteReturnFp error" {
    const operands = OperandsResult{
        .dst = MaybeRelocatable.fromU64(8),
        .res = MaybeRelocatable.fromU64(8),
        .op_0 = MaybeRelocatable.fromSegment(0, 1),
        .op_1 = MaybeRelocatable.fromU64(10),
        .dst_addr = .{},
        .op_0_addr = .{},
        .op_1_addr = .{},
        .deduced_operands = 0,
    };

    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    vm.run_context.fp.* = Relocatable.init(0, 6);

    try expectError(
        CairoVMError.CantWriteReturnFp,
        vm.opcodeAssertions(
            &.{
                .off_0 = 0,
                .off_1 = 1,
                .off_2 = 2,
                .dst_reg = .AP,
                .op_0_reg = .AP,
                .op_1_addr = .AP,
                .res_logic = .Add,
                .pc_update = .Regular,
                .ap_update = .Regular,
                .fp_update = .Regular,
                .opcode = .Call,
            },
            operands,
        ),
    );
}

test "CairoVM: getFeltRange for continuous memory" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.is_run_finished = true;
    try segments.segmentsUtil(
        vm.segments,
        std.testing.allocator,
        .{
            .{ .{ 1, 0 }, .{2} },
            .{ .{ 1, 1 }, .{3} },
            .{ .{ 1, 2 }, .{4} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    var expected_vec = std.ArrayList(Felt252).init(std.testing.allocator);
    defer expected_vec.deinit();

    try expected_vec.append(Felt252.fromInteger(2));
    try expected_vec.append(Felt252.fromInteger(3));
    try expected_vec.append(Felt252.fromInteger(4));

    var actual = try vm.getFeltRange(
        Relocatable.init(1, 0),
        3,
    );
    defer actual.deinit();

    // Test checks
    try expectEqualSlices(
        Felt252,
        expected_vec.items,
        actual.items,
    );
}

test "CairoVM: getFeltRange for Relocatable instead of Felt" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.is_run_finished = true;
    try segments.segmentsUtil(
        vm.segments,
        std.testing.allocator,
        .{
            .{ .{ 0, 0 }, .{0} },
            .{ .{ 0, 1 }, .{0} },
            .{ .{ 0, 2 }, .{ 1, 4 } },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    try expectError(
        MemoryError.ExpectedInteger,
        vm.getFeltRange(
            Relocatable.init(0, 0),
            3,
        ),
    );
}

test "CairoVM: getFeltRange for out of bounds memory" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.is_run_finished = true;
    try segments.segmentsUtil(
        vm.segments,
        std.testing.allocator,
        .{
            .{ .{ 1, 0 }, .{4} },
            .{ .{ 1, 1 }, .{5} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Test checks
    try expectError(
        MemoryError.UnknownMemoryCell,
        vm.getFeltRange(
            Relocatable.init(1, 0),
            4,
        ),
    );
}

test "CairoVM: getFeltRange for non continuous memory" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    vm.is_run_finished = true;
    try segments.segmentsUtil(
        vm.segments,
        std.testing.allocator,
        .{
            .{ .{ 1, 0 }, .{4} },
            .{ .{ 1, 1 }, .{5} },
            .{ .{ 1, 3 }, .{6} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Test checks
    try expectError(
        MemoryError.UnknownMemoryCell,
        vm.getFeltRange(
            Relocatable.init(1, 0),
            4,
        ),
    );
}

test "CairoVM: loadData should give the correct segment size" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();
    const segment = try vm.segments.addSegment();

    // Prepare data to load into memory
    var data = std.ArrayList(MaybeRelocatable).init(allocator);
    defer data.deinit();
    try data.append(MaybeRelocatable.fromU256(1));
    try data.append(MaybeRelocatable.fromU256(2));
    try data.append(MaybeRelocatable.fromU256(3));
    try data.append(MaybeRelocatable.fromU256(4));

    // Load data into memory segment
    const actual = try vm.loadData(segment, &data);
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Perform assertions
    try expectEqual(
        Relocatable.init(0, 4),
        actual,
    );

    // Check the segment size
    var segment_size = try vm.segments.computeEffectiveSize(false);

    // Assert segment size count and the value at index 0
    try expectEqual(@as(usize, 1), segment_size.count());
    try expectEqual(@as(u32, 4), segment_size.get(0).?);
}

test "CairoVM: loadData should resize the instruction cache with null elements if ptr segment index is zero" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();
    const segment = try vm.segments.addSegment();

    // Prepare data to load into memory
    var data = std.ArrayList(MaybeRelocatable).init(allocator);
    defer data.deinit();
    try data.append(MaybeRelocatable.fromU256(1));
    try data.append(MaybeRelocatable.fromU256(2));
    try data.append(MaybeRelocatable.fromU256(3));
    try data.append(MaybeRelocatable.fromU256(4));

    // Load data into memory segment
    const actual = try vm.loadData(segment, &data);
    _ = actual;
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Prepare an expected instruction cache with null elements
    var expected_instruction_cache = ArrayList(?Instruction).init(allocator);
    defer expected_instruction_cache.deinit();
    try expected_instruction_cache.appendNTimes(null, 4);

    // Assert the instruction cache after loading data
    try expectEqualSlices(
        ?Instruction,
        expected_instruction_cache.items,
        vm.instruction_cache.items,
    );
}

test "CairoVM: loadData should not resize the instruction cache if ptr segment index is not zero" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();
    _ = try vm.segments.addSegment();
    const segment = try vm.segments.addSegment();

    // Prepare data to load into memory
    var data = std.ArrayList(MaybeRelocatable).init(allocator);
    defer data.deinit();
    try data.append(MaybeRelocatable.fromU256(1));
    try data.append(MaybeRelocatable.fromU256(2));
    try data.append(MaybeRelocatable.fromU256(3));
    try data.append(MaybeRelocatable.fromU256(4));

    // Load data into memory segment
    const actual = try vm.loadData(segment, &data);
    _ = actual;
    defer vm.segments.memory.deinitData(std.testing.allocator);

    // Prepare an empty expected instruction cache
    var expected_instruction_cache = ArrayList(?Instruction).init(allocator);
    defer expected_instruction_cache.deinit();

    // Assert the instruction cache after loading data
    try expectEqualSlices(
        ?Instruction,
        expected_instruction_cache.items,
        vm.instruction_cache.items,
    );
}

test "CairoVM: addRelocationRule should add new relocation rule to the VM memory" {

    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    // Test checks
    try vm.addRelocationRule(
        Relocatable.init(-1, 0),
        Relocatable.init(1, 2),
    );
    try vm.addRelocationRule(
        Relocatable.init(-2, 0),
        Relocatable.init(-1, 1),
    );

    try expectError(
        MemoryError.AddressNotInTemporarySegment,
        vm.addRelocationRule(
            Relocatable.init(5, 0),
            Relocatable.init(0, 0),
        ),
    );
    try expectError(
        MemoryError.NonZeroOffset,
        vm.addRelocationRule(
            Relocatable.init(-3, 6),
            Relocatable.init(0, 0),
        ),
    );
    try expectError(
        MemoryError.DuplicatedRelocation,
        vm.addRelocationRule(
            Relocatable.init(-1, 0),
            Relocatable.init(0, 0),
        ),
    );
}

test "CairoVM: getPublicMemoryAddresses should return UnrelocatedMemory error if no relocation table in CairoVM" {
    // Test setup
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    try expectError(
        MemoryError.UnrelocatedMemory,
        vm.getPublicMemoryAddresses(),
    );
}

test "CairoVM: getPublicMemoryAddresses should return Cairo VM Memory error if segment method returns an error" {
    // Test setup
    // Initialize the allocator for testing purposes.
    const allocator = std.testing.allocator;

    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    // Initialize the relocation table in the VM instance.
    vm.relocation_table = std.ArrayList(usize).init(allocator);
    // Ensure proper deallocation of resources.
    defer vm.deinit();

    // Add five segments to the memory segment manager.
    for (0..5) |_| {
        _ = try vm.segments.addSegment();
    }

    // Initialize lists to hold public memory offsets.
    var public_memory_offsets = std.ArrayList(?std.ArrayList(std.meta.Tuple(&.{ usize, usize }))).init(allocator);
    // Ensure proper deallocation of resources.
    defer public_memory_offsets.deinit();

    // Initialize inner lists to store specific offsets for segments.
    var inner_list_1 = std.ArrayList(std.meta.Tuple(&.{ usize, usize })).init(allocator);
    // Ensure proper deallocation of resources.
    defer inner_list_1.deinit();
    try inner_list_1.append(.{ 0, 0 });
    try inner_list_1.append(.{ 1, 1 });

    var inner_list_2 = std.ArrayList(std.meta.Tuple(&.{ usize, usize })).init(allocator);
    // Ensure proper deallocation of resources.
    defer inner_list_2.deinit();
    // Inline to append specific offsets to the list.
    inline for (0..8) |i| {
        try inner_list_2.append(.{ i, 0 });
    }

    var inner_list_5 = std.ArrayList(std.meta.Tuple(&.{ usize, usize })).init(allocator);
    // Ensure proper deallocation of resources.
    defer inner_list_5.deinit();
    try inner_list_5.append(.{ 1, 2 });

    // Append inner lists containing offsets to public_memory_offsets.
    try public_memory_offsets.append(inner_list_1);
    try public_memory_offsets.append(inner_list_2);
    try public_memory_offsets.append(null);
    try public_memory_offsets.append(null);
    try public_memory_offsets.append(inner_list_5);

    // Perform assertions and memory operations.
    // Add additional segments to the VM's segment manager.
    try expectEqual(
        vm.segments.addSegment(),
        Relocatable.init(5, 0),
    );
    try expectEqual(
        vm.segments.addSegment(),
        Relocatable.init(6, 0),
    );
    // Set memory within segments.
    try vm.segments.memory.set(
        allocator,
        Relocatable.init(5, 4),
        MaybeRelocatable.fromU256(0),
    );
    // Ensure proper deallocation of memory data.
    defer vm.segments.memory.deinitData(allocator);

    // Finalize segments with sizes and offsets.
    // Iterate through segment sizes and finalize segments.
    for ([_]u8{ 3, 8, 0, 1, 2 }, 0..) |size, i| {
        try vm.segments.finalize(
            i,
            size,
            public_memory_offsets.items[i],
        );
    }

    // Segment offsets less than the number of segments.
    // Append specific segment offsets to the relocation table.
    for ([_]usize{ 1, 4, 12, 13 }) |offset| {
        try vm.relocation_table.?.append(offset);
    }

    // Validate if the function throws the expected CairoVMError.Memory.
    try expectError(
        CairoVMError.Memory,
        vm.getPublicMemoryAddresses(),
    );
}

test "CairoVM: getPublicMemoryAddresses should return a proper ArrayList if success" {
    // Test setup
    // Initialize the allocator for testing purposes.
    const allocator = std.testing.allocator;
    // Create a new VM instance.
    var vm = try CairoVM.init(allocator, .{});
    // Initialize the relocation table in the VM instance.
    vm.relocation_table = std.ArrayList(usize).init(allocator);
    // Ensure proper deallocation of resources.
    defer vm.deinit();

    // Add five segments to the memory segment manager.
    for (0..5) |_| {
        _ = try vm.segments.addSegment();
    }

    // Initialize lists to hold public memory offsets.
    var public_memory_offsets = std.ArrayList(?std.ArrayList(std.meta.Tuple(&.{ usize, usize }))).init(allocator);
    // Ensure proper deallocation of resources.
    defer public_memory_offsets.deinit();

    // Initialize inner lists to store specific offsets for segments.
    var inner_list_1 = std.ArrayList(std.meta.Tuple(&.{ usize, usize })).init(allocator);
    // Ensure proper deallocation of resources.
    defer inner_list_1.deinit();
    try inner_list_1.append(.{ 0, 0 });
    try inner_list_1.append(.{ 1, 1 });

    var inner_list_2 = std.ArrayList(std.meta.Tuple(&.{ usize, usize })).init(allocator);
    // Ensure proper deallocation of resources.
    defer inner_list_2.deinit();
    // Inline to append specific offsets to the list.
    inline for (0..8) |i| {
        try inner_list_2.append(.{ i, 0 });
    }

    var inner_list_5 = std.ArrayList(std.meta.Tuple(&.{ usize, usize })).init(allocator);
    // Ensure proper deallocation of resources.
    defer inner_list_5.deinit();
    try inner_list_5.append(.{ 1, 2 });

    // Append inner lists containing offsets to public_memory_offsets.
    try public_memory_offsets.append(inner_list_1);
    try public_memory_offsets.append(inner_list_2);
    try public_memory_offsets.append(null);
    try public_memory_offsets.append(null);
    try public_memory_offsets.append(inner_list_5);

    // Perform assertions and memory operations.
    // Add additional segments to the VM's segment manager.
    try expectEqual(
        vm.segments.addSegment(),
        Relocatable.init(5, 0),
    );
    try expectEqual(
        vm.segments.addSegment(),
        Relocatable.init(6, 0),
    );
    // Set memory within segments.
    try vm.segments.memory.set(
        allocator,
        Relocatable.init(5, 4),
        MaybeRelocatable.fromU256(0),
    );
    // Ensure proper deallocation of memory data.
    defer vm.segments.memory.deinitData(allocator);

    // Finalize segments with sizes and offsets.
    // Iterate through segment sizes and finalize segments.
    for ([_]u8{ 3, 8, 0, 1, 2 }, 0..) |size, i| {
        try vm.segments.finalize(
            i,
            size,
            public_memory_offsets.items[i],
        );
    }

    // Generate specific segment offsets for the relocation table.
    for ([_]usize{ 1, 4, 12, 12, 13, 15, 20 }) |offset| {
        try vm.relocation_table.?.append(offset);
    }

    // Get public memory addresses based on segment offsets.
    const public_memory_addresses = try vm.getPublicMemoryAddresses();
    // Ensure proper deallocation of retrieved addresses.
    defer public_memory_addresses.deinit();

    // Define the expected list of public memory addresses.
    const expected = [_]std.meta.Tuple(&.{ usize, usize }){
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
        std.meta.Tuple(&.{ usize, usize }),
        &expected,
        public_memory_addresses.items,
    );
}

test "CairoVM: getReturnValues should return a continuous range of memory values starting from a specified address." {
    var vm = try CairoVM.init(std.testing.allocator, .{});
    const ap = Relocatable.init(1, 4);
    vm.run_context.ap.* = ap;
    defer vm.deinit();

    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 1, 0 }, .{1} },
            .{ .{ 1, 1 }, .{2} },
            .{ .{ 1, 2 }, .{3} },
            .{ .{ 1, 3 }, .{4} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    var expected = ArrayList(MaybeRelocatable).init(std.testing.allocator);
    defer expected.deinit();

    try expected.append(MaybeRelocatable.fromU256(1));
    try expected.append(MaybeRelocatable.fromU256(2));
    try expected.append(MaybeRelocatable.fromU256(3));
    try expected.append(MaybeRelocatable.fromU256(4));

    var actual = try vm.getReturnValues(4);
    defer actual.deinit();

    try expectEqualSlices(MaybeRelocatable, expected.items, actual.items);
}

test "CairoVM: getReturnValues should return a memory error when Ap is 0" {
    var vm = try CairoVM.init(std.testing.allocator, .{});
    defer vm.deinit();

    try vm.segments.memory.setUpMemory(
        std.testing.allocator,
        .{
            .{ .{ 1, 0 }, .{1} },
            .{ .{ 1, 1 }, .{2} },
            .{ .{ 1, 2 }, .{3} },
            .{ .{ 1, 3 }, .{4} },
        },
    );
    defer vm.segments.memory.deinitData(std.testing.allocator);

    try expectError(MemoryError.FailedToGetReturnValues, vm.getReturnValues(3));
}

test "CairoVM: verifyAutoDeductionsForAddr bitwise" {
    const allocator = std.testing.allocator;

    var bitwise_builtin = BitwiseBuiltinRunner.initDefault();
    bitwise_builtin.base = 2;
    var builtin = BuiltinRunner{ .Bitwise = bitwise_builtin };

    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    try vm.segments.memory.setUpMemory(
        allocator,
        .{
            .{ .{ 2, 0 }, .{12} },
            .{ .{ 2, 1 }, .{10} },
            .{ .{ 2, 2 }, .{8} },
        },
    );
    defer vm.segments.memory.deinitData(allocator);

    try expectEqual(void, @TypeOf(try vm.verifyAutoDeductionsForAddr(allocator, Relocatable.init(2, 0), &builtin)));
    try expectEqual(void, @TypeOf(try vm.verifyAutoDeductionsForAddr(allocator, Relocatable.init(2, 1), &builtin)));
    try expectEqual(void, @TypeOf(try vm.verifyAutoDeductionsForAddr(allocator, Relocatable.init(2, 2), &builtin)));
}

test "CairoVM: verifyAutoDeductionsForAddr throws InconsistentAutoDeduction" {
    const allocator = std.testing.allocator;

    var bitwise_builtin = BitwiseBuiltinRunner.initDefault();
    bitwise_builtin.base = 2;

    var builtin = BuiltinRunner{ .Bitwise = bitwise_builtin };

    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    try vm.segments.memory.setUpMemory(
        allocator,
        .{
            .{ .{ 2, 0 }, .{12} },
            .{ .{ 2, 1 }, .{10} },
            .{ .{ 2, 2 }, .{7} },
        },
    );
    defer vm.segments.memory.deinitData(allocator);

    try expectError(CairoVMError.InconsistentAutoDeduction, vm.verifyAutoDeductionsForAddr(allocator, Relocatable.init(2, 2), &builtin));
}

test "CairoVM: verifyAutoDeductions for bitwise builtin runner" {
    const allocator = std.testing.allocator;

    var bitwise_builtin = BitwiseBuiltinRunner.initDefault();
    bitwise_builtin.base = 2;
    const builtin = BuiltinRunner{ .Bitwise = bitwise_builtin };

    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    try vm.builtin_runners.append(builtin);

    try vm.segments.memory.setUpMemory(
        allocator,
        .{
            .{ .{ 2, 0 }, .{12} },
            .{ .{ 2, 1 }, .{10} },
            .{ .{ 2, 2 }, .{8} },
        },
    );
    defer vm.segments.memory.deinitData(allocator);

    const result = try vm.verifyAutoDeductions(allocator);
    try expectEqual(void, @TypeOf(result));
}

test "CairoVM: verifyAutoDeductions for bitwise builtin runner throws InconsistentAutoDeduction" {
    const allocator = std.testing.allocator;

    var bitwise_builtin = BitwiseBuiltinRunner.initDefault();
    bitwise_builtin.base = 2;
    const builtin = BuiltinRunner{ .Bitwise = bitwise_builtin };

    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    try vm.builtin_runners.append(builtin);

    try vm.segments.memory.setUpMemory(
        allocator,
        .{
            .{ .{ 2, 0 }, .{12} },
            .{ .{ 2, 1 }, .{10} },
            .{ .{ 2, 2 }, .{7} },
        },
    );

    defer vm.segments.memory.deinitData(allocator);

    try expectError(CairoVMError.InconsistentAutoDeduction, vm.verifyAutoDeductions(allocator));
}

test "CairoVM: verifyAutoDeductions for keccak builtin runner" {
    const allocator = std.testing.allocator;

    var keccak_instance_def = try KeccakInstanceDef.initDefault(allocator);
    const keccak_builtin = KeccakBuiltinRunner.init(
        allocator,
        &keccak_instance_def,
        true,
    );
    const builtin = BuiltinRunner{ .Keccak = keccak_builtin };

    var vm = try CairoVM.init(allocator, .{});
    defer vm.deinit();

    try vm.segments.memory.setUpMemory(
        allocator,
        .{
            .{ .{ 0, 16 }, .{43} },
            .{ .{ 0, 17 }, .{199} },
            .{ .{ 0, 18 }, .{0} },
            .{ .{ 0, 19 }, .{0} },
            .{ .{ 0, 20 }, .{0} },
            .{ .{ 0, 21 }, .{0} },
            .{ .{ 0, 22 }, .{0} },
            .{ .{ 0, 23 }, .{1} },
            .{ .{ 0, 24 }, .{564514457304291355949254928395241013971879337011439882107889} },
            .{ .{ 0, 25 }, .{1006979841721999878391288827876533441431370448293338267890891} },
            .{ .{ 0, 26 }, .{811666116505725183408319428185457775191826596777361721216040} },
        },
    );
    defer vm.segments.memory.deinitData(allocator);

    try vm.builtin_runners.append(builtin);

    const result = try vm.verifyAutoDeductions(allocator);

    try expectEqual(void, @TypeOf(result));
}
