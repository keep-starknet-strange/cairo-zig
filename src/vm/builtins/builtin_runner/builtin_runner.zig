const std = @import("std");
const Allocator = std.mem.Allocator;
const Tuple = std.meta.Tuple;

const MemorySegmentManager = @import("../../memory/segments.zig").MemorySegmentManager;

const BitwiseBuiltinRunner = @import("./bitwise.zig").BitwiseBuiltinRunner;
const EcOpBuiltinRunner = @import("./ec_op.zig").EcOpBuiltinRunner;
const HashBuiltinRunner = @import("./hash.zig").HashBuiltinRunner;
const KeccakBuiltinRunner = @import("./keccak.zig").KeccakBuiltinRunner;
const OutputBuiltinRunner = @import("./output.zig").OutputBuiltinRunner;
const PoseidonBuiltinRunner = @import("./poseidon.zig").PoseidonBuiltinRunner;
const RangeCheckBuiltinRunner = @import("./range_check.zig").RangeCheckBuiltinRunner;
const SegmentArenaBuiltinRunner = @import("./segment_arena.zig").SegmentArenaBuiltinRunner;
const SignatureBuiltinRunner = @import("./signature.zig").SignatureBuiltinRunner;
const Relocatable = @import("../../memory/relocatable.zig").Relocatable;
const MaybeRelocatable = @import("../../memory/relocatable.zig").MaybeRelocatable;
const Memory = @import("../../memory/memory.zig").Memory;
const ArrayList = std.ArrayList;

/// Built-in runner
pub const BuiltinRunner = union(enum) {
    const Self = @This();

    /// Bitwise built-in runner for bitwise operations.
    Bitwise: BitwiseBuiltinRunner,
    /// EC Operation built-in runner for elliptic curve operations.
    EcOp: EcOpBuiltinRunner,
    /// Hash built-in runner for hash operations.
    Hash: HashBuiltinRunner,
    /// Output built-in runner for output operations.
    Output: OutputBuiltinRunner,
    /// Range Check built-in runner for range check operations.
    RangeCheck: RangeCheckBuiltinRunner,
    /// Keccak built-in runner for Keccak operations.
    Keccak: KeccakBuiltinRunner,
    /// Signature built-in runner for signature operations.
    Signature: SignatureBuiltinRunner,
    /// Poseidon built-in runner for Poseidon operations.
    Poseidon: PoseidonBuiltinRunner,
    /// Segment Arena built-in runner for segment arena operations.
    SegmentArena: SegmentArenaBuiltinRunner,

    /// Get the base value of the built-in runner.
    ///
    /// This function returns the base value specific to the type of built-in runner.
    ///
    /// # Returns
    ///
    /// The base value as a `usize`.
    pub fn base(self: *const Self) usize {
        return switch (self.*) {
            .SegmentArena => |*segment_arena| @intCast(segment_arena.base.segment_index),
            inline else => |*case| case.base,
        };
    }

    /// Initializes a builtin with its required memory segments.
    ///
    /// # Arguments
    ///
    /// - `segments`: A pointer to the MemorySegmentManager managing memory segments.
    pub fn initSegments(self: *Self, segments: *MemorySegmentManager) !void {
        switch (self.*) {
            inline else => |*case| try case.initSegments(segments),
        }
    }

    /// Derives necessary stack for a builtin.
    ///
    /// # Arguments
    ///
    ///  - `allocator`: The allocator to initialize the ArrayList.
    pub fn initialStack(self: *Self, allocator: Allocator) !ArrayList(MaybeRelocatable) {
        return switch (self.*) {
            inline else => |*case| try case.initialStack(allocator),
        };
    }

    /// Deduces memory cell information for the built-in runner.
    ///
    /// This function deduces memory cell information for the specific type of built-in runner.
    ///
    /// # Arguments
    ///
    /// - `address`: The address of the memory cell.
    /// - `memory`: The memory manager for the current context.
    ///
    /// # Returns
    ///
    /// A `MaybeRelocatable` representing the deduced memory cell information, or an error if deduction fails.
    pub fn deduceMemoryCell(
        self: *Self,
        allocator: Allocator,
        address: Relocatable,
        memory: *Memory,
    ) !?MaybeRelocatable {
        return switch (self.*) {
            .EcOp => |*ec| try ec.deduceMemoryCell(allocator, address, memory),
            .Keccak => |*keccak| try keccak.deduceMemoryCell(allocator, address, memory),
            .Poseidon => |*poseidon| try poseidon.deduceMemoryCell(allocator, address, memory),
            .Bitwise => |bitwise| try bitwise.deduceMemoryCell(address, memory),
            .Hash => |*hash| try hash.deduceMemoryCell(address, memory),
            inline else => |*case| case.deduceMemoryCell(address, memory),
        };
    }

    /// Retrieves the memory segment addresses associated with the built-in runner.
    ///
    /// This function returns a `Tuple` containing the starting address and optional stop address
    /// for each memory segment used by the specific type of built-in runner. The stop address may
    /// be `null` if the built-in runner doesn't have a distinct stop address for its memory segment.
    ///
    /// # Returns
    ///
    /// A `Tuple` containing the memory segment addresses as follows:
    /// - The starting address of the memory segment.
    /// - An optional stop address of the memory segment (may be `null`).
    pub fn getMemorySegmentAddresses(self: *Self) Tuple(&.{ usize, ?usize }) {
        // TODO: fill-in missing builtins when implemented
        return switch (self.*) {
            .Signature, .SegmentArena => .{ 0, 0 },
            inline else => |*case| case.getMemorySegmentAddresses(),
        };
    }
};
