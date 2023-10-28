const std = @import("std");
const Signature = @import("../../../math/crypto/signatures.zig").Signature;
const relocatable = @import("../../memory/relocatable.zig");
const Felt252 = @import("../../../math/fields/starknet.zig").Felt252;
const ecdsa_instance_def = @import("../../types/ecdsa_instance_def.zig");

const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;

/// Signature built-in runner
pub const SignatureBuiltinRunner = struct {
    const Self = @This();

    /// Included boolean flag
    included: bool,
    /// Ratio
    ratio: ?u32,
    /// Base
    base: usize,
    /// Number of cells per instance
    cells_per_instance: u32,
    /// Number of input cells
    n_input_cells: u32,
    /// Total number of bits
    _total_n_bits: u32,
    /// Stop pointer
    stop_ptr: ?usize,
    /// Number of instances per component
    instances_per_component: u32,
    /// Signatures HashMap
    signatures: AutoHashMap(relocatable.Relocatable, Signature),

    /// Create a new SignatureBuiltinRunner instance.
    ///
    /// This function initializes a new `SignatureBuiltinRunner` instance with the provided
    /// `allocator`, `instance_def`, and `included` values.
    ///
    /// # Arguments
    ///
    /// - `allocator`: An allocator for initializing the `signatures` HashMap.
    /// - `instance_def`: A pointer to the `EcdsaInstanceDef` for this runner.
    /// - `included`: A boolean flag indicating whether this runner is included.
    ///
    /// # Returns
    ///
    /// A new `SignatureBuiltinRunner` instance.
    pub fn new(allocator: Allocator, instance_def: *ecdsa_instance_def.EcdsaInstanceDef, included: bool) Self {
        return .{
            .included = included,
            .ratio = instance_def.ratio,
            .base = 0,
            .cell_per_instance = 2,
            .n_input_cells = 2,
            ._total_n_bits = 251,
            .stop_ptr = null,
            .instances_per_component = 1,
            .signatures = AutoHashMap(relocatable.Relocatable, Signature).init(allocator),
        };
    }

    /// Get the base value of this signature runner.
    ///
    /// # Returns
    ///
    /// The base value as a `usize`.
    pub fn get_base(self: *const Self) usize {
        return self.base;
    }
};
