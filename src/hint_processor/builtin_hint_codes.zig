pub const TEMPORARY_ARRAY = "ids.temporary_array = segments.add_temp_segment()";

pub const RELOCATE_SEGMENT = "memory.add_relocation_rule(src_ptr=ids.src_ptr, dest_ptr=ids.dest_ptr)";

pub const GET_FELT_BIT_LENGTH =
    \\x = ids.x
    \\ids.bit_length = x.bit_length()
;

pub const POW = "ids.locs.bit = (ids.prev_locs.exp % PRIME) & 1";

pub const ASSERT_NN = "from starkware.cairo.common.math_utils import assert_integer\nassert_integer(ids.a)\nassert 0 <= ids.a % PRIME < range_check_builtin.bound, f'a = {ids.a} is out of range.'";
pub const VERIFY_ECDSA_SIGNATURE = "ecdsa_builtin.add_signature(ids.ecdsa_ptr.address_, (ids.signature_r, ids.signature_s))";
pub const IS_POSITIVE = "from starkware.cairo.common.math_utils import is_positive\nids.is_positive = 1 if is_positive(\n    value=ids.value, prime=PRIME, rc_bound=range_check_builtin.bound) else 0";
pub const ASSERT_NOT_ZERO = "from starkware.cairo.common.math_utils import assert_integer\nassert_integer(ids.value)\nassert ids.value % PRIME != 0, f'assert_not_zero failed: {ids.value} = 0.'";
pub const IS_QUAD_RESIDUE =
    \\from starkware.crypto.signature.signature import FIELD_PRIME
    \\from starkware.python.math_utils import div_mod, is_quad_residue, sqrt
    \\
    \\x = ids.x
    \\if is_quad_residue(x, FIELD_PRIME):
    \\    ids.y = sqrt(x, FIELD_PRIME)
    \\else:
    \\    ids.y = sqrt(div_mod(x, 3, FIELD_PRIME), FIELD_PRIME)`
;

pub const ASSERT_NOT_EQUAL =
    \\from starkware.cairo.lang.vm.relocatable import RelocatableValue
    \\both_ints = isinstance(ids.a, int) and isinstance(ids.b, int)
    \\both_relocatable = (
    \\    isinstance(ids.a, RelocatableValue) and isinstance(ids.b, RelocatableValue) and
    \\    ids.a.segment_index == ids.b.segment_index)
    \\assert both_ints or both_relocatable, \
    \\    f'assert_not_equal failed: non-comparable values: {ids.a}, {ids.b}.'
    \\assert (ids.a - ids.b) % PRIME != 0, f'assert_not_equal failed: {ids.a} = {ids.b}.'
;

pub const SQRT =
    \\from starkware.python.math_utils import isqrt
    \\value = ids.value % PRIME
    \\assert value < 2 ** 250, f"value={value} is outside of the range [0, 2**250)."
    \\assert 2 ** 250 < PRIME
    \\ids.root = isqrt(value)
;

pub const UNSIGNED_DIV_REM =
    \\from starkware.cairo.common.math_utils import assert_integer
    \\assert_integer(ids.div)
    \\assert 0 < ids.div <= PRIME // range_check_builtin.bound, \
    \\    f'div={hex(ids.div)} is out of the valid range.'
    \\ids.q, ids.r = divmod(ids.value, ids.div)
;

pub const SIGNED_DIV_REM =
    \\from starkware.cairo.common.math_utils import as_int, assert_integer
    \\
    \\assert_integer(ids.div)
    \\assert 0 < ids.div <= PRIME // range_check_builtin.bound, \
    \\    f'div={hex(ids.div)} is out of the valid range.'
    \\
    \\assert_integer(ids.bound)
    \\assert ids.bound <= range_check_builtin.bound // 2, \
    \\    f'bound={hex(ids.bound)} is out of the valid range.'
    \\
    \\int_value = as_int(ids.value, PRIME)
    \\q, ids.r = divmod(int_value, ids.div)
    \\
    \\assert -ids.bound <= q < ids.bound, \
    \\    f'{int_value} / {ids.div} = {q} is out of the range [{-ids.bound}, {ids.bound}).'
    \\
    \\ids.biased_q = q + ids.bound
;

pub const ASSERT_LE_FELT =
    \\import itertools
    \\
    \\from starkware.cairo.common.math_utils import assert_integer
    \\assert_integer(ids.a)
    \\assert_integer(ids.b)
    \\a = ids.a % PRIME
    \\b = ids.b % PRIME
    \\assert a <= b, f'a = {a} is not less than or equal to b = {b}.'
    \\
    \\# Find an arc less than PRIME / 3, and another less than PRIME / 2.
    \\lengths_and_indices = [(a, 0), (b - a, 1), (PRIME - 1 - b, 2)]
    \\lengths_and_indices.sort()
    \\assert lengths_and_indices[0][0] <= PRIME // 3 and lengths_and_indices[1][0] <= PRIME // 2
    \\excluded = lengths_and_indices[2][1]
    \\
    \\memory[ids.range_check_ptr + 1], memory[ids.range_check_ptr + 0] = (
    \\    divmod(lengths_and_indices[0][0], ids.PRIME_OVER_3_HIGH))
    \\memory[ids.range_check_ptr + 3], memory[ids.range_check_ptr + 2] = (
    \\    divmod(lengths_and_indices[1][0], ids.PRIME_OVER_2_HIGH))
;

pub const ASSERT_LE_FELT_EXCLUDED_0 = "memory[ap] = 1 if excluded != 0 else 0";

pub const ASSERT_LE_FELT_EXCLUDED_1 = "memory[ap] = 1 if excluded != 1 else 0";

pub const ASSERT_LE_FELT_EXCLUDED_2 = "assert excluded == 2";

pub const ASSERT_LT_FELT =
    \\from starkware.cairo.common.math_utils import assert_integer
    \\assert_integer(ids.a)
    \\assert_integer(ids.b)
    \\assert (ids.a % PRIME) < (ids.b % PRIME), \
    \\    f'a = {ids.a % PRIME} is not less than b = {ids.b % PRIME}.'
;

pub const ASSERT_250_BITS =
    \\from starkware.cairo.common.math_utils import as_int
    \\
    \\# Correctness check.
    \\value = as_int(ids.value, PRIME) % PRIME
    \\assert value < ids.UPPER_BOUND, f'{value} is outside of the range [0, 2**250).'
    \\
    \\# Calculation for the assertion.
    \\ids.high, ids.low = divmod(ids.value, ids.SHIFT)
;

pub const SPLIT_FELT =
    \\from starkware.cairo.common.math_utils import assert_integer
    \\assert ids.MAX_HIGH < 2**128 and ids.MAX_LOW < 2**128
    \\assert PRIME - 1 == ids.MAX_HIGH * 2**128 + ids.MAX_LOW
    \\assert_integer(ids.value)
    \\ids.low = ids.value & ((1 << 128) - 1)
    \\ids.high = ids.value >> 128
;

pub const SPLIT_INT = "memory[ids.output] = res = (int(ids.value) % PRIME) % ids.base\nassert res < ids.bound, f'split_int(): Limb {res} is out of range.'";

pub const SPLIT_INT_ASSERT_RANGE = "assert ids.value == 0, 'split_int(): value is out of range.'";

pub const ADD_SEGMENT = "memory[ap] = segments.add()";

pub const VM_ENTER_SCOPE = "vm_enter_scope()";
pub const VM_EXIT_SCOPE = "vm_exit_scope()";

pub const MEMCPY_ENTER_SCOPE = "vm_enter_scope({'n': ids.len})";
pub const NONDET_N_GREATER_THAN_10 = "memory[ap] = to_felt_or_relocatable(ids.n >= 10)";
pub const NONDET_N_GREATER_THAN_2 = "memory[ap] = to_felt_or_relocatable(ids.n >= 2)";

pub const UNSAFE_KECCAK =
    \\from eth_hash.auto import keccak
    \\
    \\data, length = ids.data, ids.length
    \\
    \\if '__keccak_max_size' in globals():
    \\    assert length <= __keccak_max_size, \
    \\        f'unsafe_keccak() can only be used with length<={__keccak_max_size}. ' \
    \\        f'Got: length={length}.'
    \\
    \\keccak_input = bytearray()
    \\for word_i, byte_i in enumerate(range(0, length, 16)):
    \\    word = memory[data + word_i]
    \\    n_bytes = min(16, length - byte_i)
    \\    assert 0 <= word < 2 ** (8 * n_bytes)
    \\    keccak_input += word.to_bytes(n_bytes, 'big')
    \\
    \\hashed = keccak(keccak_input)
    \\ids.high = int.from_bytes(hashed[:16], 'big')
    \\ids.low = int.from_bytes(hashed[16:32], 'big')
;

pub const UNSAFE_KECCAK_FINALIZE =
    \\from eth_hash.auto import keccak
    \\keccak_input = bytearray()
    \\n_elms = ids.keccak_state.end_ptr - ids.keccak_state.start_ptr
    \\for word in memory.get_range(ids.keccak_state.start_ptr, n_elms):
    \\    keccak_input += word.to_bytes(16, 'big')
    \\hashed = keccak(keccak_input)
    \\ids.high = int.from_bytes(hashed[:16], 'big')
    \\ids.low = int.from_bytes(hashed[16:32], 'big')
;

pub const SPLIT_INPUT_3 = "ids.high3, ids.low3 = divmod(memory[ids.inputs + 3], 256)";
pub const SPLIT_INPUT_6 = "ids.high6, ids.low6 = divmod(memory[ids.inputs + 6], 256 ** 2)";
pub const SPLIT_INPUT_9 = "ids.high9, ids.low9 = divmod(memory[ids.inputs + 9], 256 ** 3)";
pub const SPLIT_INPUT_12 =
    "ids.high12, ids.low12 = divmod(memory[ids.inputs + 12], 256 ** 4)";
pub const SPLIT_INPUT_15 =
    "ids.high15, ids.low15 = divmod(memory[ids.inputs + 15], 256 ** 5)";

pub const SPLIT_OUTPUT_0 =
    \\ids.output0_low = ids.output0 & ((1 << 128) - 1)
    \\ids.output0_high = ids.output0 >> 128
;
pub const SPLIT_OUTPUT_1 =
    \\ids.output1_low = ids.output1 & ((1 << 128) - 1)
    \\ids.output1_high = ids.output1 >> 128
;

pub const SPLIT_N_BYTES = "ids.n_words_to_copy, ids.n_bytes_left = divmod(ids.n_bytes, ids.BYTES_IN_WORD)";
pub const SPLIT_OUTPUT_MID_LOW_HIGH =
    \\tmp, ids.output1_low = divmod(ids.output1, 256 ** 7)
    \\ids.output1_high, ids.output1_mid = divmod(tmp, 2 ** 128)
;

pub const BIGINT_TO_UINT256 = "ids.low = (ids.x.d0 + ids.x.d1 * ids.BASE) & ((1 << 128) - 1)";
pub const UINT256_ADD =
    \\sum_low = ids.a.low + ids.b.low
    \\ids.carry_low = 1 if sum_low >= ids.SHIFT else 0
    \\sum_high = ids.a.high + ids.b.high + ids.carry_low
    \\ids.carry_high = 1 if sum_high >= ids.SHIFT else 0
;

pub const UINT256_ADD_LOW =
    \\sum_low = ids.a.low + ids.b.low
    \\ids.carry_low = 1 if sum_low >= ids.SHIFT else 0
;

pub const UINT128_ADD =
    \\res = ids.a + ids.b
    \\ids.carry = 1 if res >= ids.SHIFT else 0
;

pub const UINT256_SUB =
    \\def split(num: int, num_bits_shift: int = 128, length: int = 2):
    \\    a = []
    \\    for _ in range(length):
    \\        a.append( num & ((1 << num_bits_shift) - 1) )
    \\        num = num >> num_bits_shift
    \\    return tuple(a)
    \\
    \\def pack(z, num_bits_shift: int = 128) -> int:
    \\    limbs = (z.low, z.high)
    \\    return sum(limb << (num_bits_shift * i) for i, limb in enumerate(limbs))
    \\
    \\a = pack(ids.a)
    \\b = pack(ids.b)
    \\res = (a - b)%2**256
    \\res_split = split(res)
    \\ids.res.low = res_split[0]
    \\ids.res.high = res_split[1]
;

pub const UINT256_SQRT =
    \\from starkware.python.math_utils import isqrt
    \\n = (ids.n.high << 128) + ids.n.low
    \\root = isqrt(n)
    \\assert 0 <= root < 2 ** 128
    \\ids.root.low = root
    \\ids.root.high = 0
;

pub const UINT256_SQRT_FELT =
    \\from starkware.python.math_utils import isqrt
    \\n = (ids.n.high << 128) + ids.n.low
    \\root = isqrt(n)
    \\assert 0 <= root < 2 ** 128
    \\ids.root = root
;

pub const UINT256_SIGNED_NN = "memory[ap] = 1 if 0 <= (ids.a.high % PRIME) < 2 ** 127 else 0";

pub const UINT256_UNSIGNED_DIV_REM =
    \\a = (ids.a.high << 128) + ids.a.low
    \\div = (ids.div.high << 128) + ids.div.low
    \\quotient, remainder = divmod(a, div)
    \\
    \\ids.quotient.low = quotient & ((1 << 128) - 1)
    \\ids.quotient.high = quotient >> 128
    \\ids.remainder.low = remainder & ((1 << 128) - 1)
    \\ids.remainder.high = remainder >> 128
;

pub const UINT256_EXPANDED_UNSIGNED_DIV_REM =
    \\a = (ids.a.high << 128) + ids.a.low
    \\div = (ids.div.b23 << 128) + ids.div.b01
    \\quotient, remainder = divmod(a, div)
    \\
    \\ids.quotient.low = quotient & ((1 << 128) - 1)
    \\ids.quotient.high = quotient >> 128
    \\ids.remainder.low = remainder & ((1 << 128) - 1)
    \\ids.remainder.high = remainder >> 128
;

pub const UINT256_MUL_DIV_MOD =
    \\a = (ids.a.high << 128) + ids.a.low
    \\b = (ids.b.high << 128) + ids.b.low
    \\div = (ids.div.high << 128) + ids.div.low
    \\quotient, remainder = divmod(a * b, div)
    \\
    \\ids.quotient_low.low = quotient & ((1 << 128) - 1)
    \\ids.quotient_low.high = (quotient >> 128) & ((1 << 128) - 1)
    \\ids.quotient_high.low = (quotient >> 256) & ((1 << 128) - 1)
    \\ids.quotient_high.high = quotient >> 384
    \\ids.remainder.low = remainder & ((1 << 128) - 1)
    \\ids.remainder.high = remainder >> 128
;

pub const SPLIT_64 =
    \\ids.low = ids.a & ((1<<64) - 1)
    \\ids.high = ids.a >> 64
;


pub const USORT_ENTER_SCOPE =
    "vm_enter_scope(dict(__usort_max_size = globals().get('__usort_max_size')))";
pub const USORT_BODY =
    \\from collections import defaultdict
    \\
    \\input_ptr = ids.input
    \\input_len = int(ids.input_len)
    \\if __usort_max_size is not None:
    \\    assert input_len <= __usort_max_size, (
    \\        f"usort() can only be used with input_len<={__usort_max_size}. "
    \\        f"Got: input_len={input_len}."
    \\    )
    \\
    \\positions_dict = defaultdict(list)
    \\for i in range(input_len):
    \\    val = memory[input_ptr + i]
    \\    positions_dict[val].append(i)
    \\
    \\output = sorted(positions_dict.keys())
    \\ids.output_len = len(output)
    \\ids.output = segments.gen_arg(output)
    \\ids.multiplicities = segments.gen_arg([len(positions_dict[k]) for k in output])
;

pub const USORT_VERIFY =
    \\last_pos = 0
    \\positions = positions_dict[ids.value][::-1]
;

pub const USORT_VERIFY_MULTIPLICITY_ASSERT = "assert len(positions) == 0";
pub const USORT_VERIFY_MULTIPLICITY_BODY =
    \\current_pos = positions.pop()
    \\ids.next_item_index = current_pos - last_pos
    \\last_pos = current_pos + 1
;

pub const MEMSET_ENTER_SCOPE = "vm_enter_scope({'n': ids.n})";
pub const MEMSET_CONTINUE_LOOP =
    \\n -= 1
    \\ids.continue_loop = 1 if n > 0 else 0
;

pub const MEMCPY_CONTINUE_COPYING = "n -= 1 ids.continue_copying = 1 if n > 0 else 0";

