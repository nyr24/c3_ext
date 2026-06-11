module ext;

import std::time;
import std::io;
import std::math;
import std::atomic;

typedef AtomicTaskState = inline Atomic{TaskState};

fn TaskState AtomicTaskState.curr(self) @inline { return self.load(); }
fn bool AtomicTaskState.is_done(self) @inline { return self.load() >= FAIL; }
fn bool AtomicTaskState.is_in_progress(self) @inline { return self.load() >= FAIL; }

enum TaskState
{
	NOT_STARTED,
	PENDING,
	FAIL,
	SUCCESS,
}

macro void swap_ptrs(#x, #y) @builtin @safemacro
{
	var temp = *#x;
	*#x = *#y;
	*#y = temp;
}

<*
 Gives execution time for provided block.
*>
macro @perf(String name = "Current Test"; @body) @builtin
{
	time::Time start = time::now();
	defer {
		time::Duration dur = time::now() - start;
		io::printfn("Duration of %s: %d", name, dur);
	}
	@body();
}

<*
 Turns provided pointer or slice to slice of char's.

 @require is_kindof_val(val, POINTER, SLICE) : "Should be Pointer or Slice"
*>
macro char[] to_byte_slice(val) @builtin
{
	var $Type = $Typeof(val);
	var $InnerT = $Type::inner;

	$switch ($Type::kind):
	$case POINTER:
		return ((char*)val)[:$InnerT::size];
	$case SLICE:
		return ((char*)val.ptr)[:val.len * $InnerT::size];
	$default:
		unreachable("Should not go here");
	$endswitch
}

<*
 Turns provided char slice to different type of slice.

 @require $OutType::kind == SLICE : "Expected be slice type as output"
*>
macro from_byte_slice(char[] val, $OutType) @builtin
{
	var $InnerT = $OutType::inner;
	return (($InnerT*)val.ptr)[:val.len / $InnerT::size];
}

<*
 Turns provided slice or pointer into slice with provided type.
*>
macro to_slice(#input, $Type, sz offset = 0, sz len = 1) @builtin @safemacro
{
	// Slice
	$if $Typeof(#input)::kind == SLICE:
		return (($Type*)(#input.ptr + offset))[:len];
	$endif
	$if $Typeof(#input)::kind == POINTER:
		// Pointer
		return (($Type*)(#input + offset))[:len];
	$else
		// Normal value (variable) from outer scope.
		return (($Type*)(&#input + offset))[:len];
	$endif
}

<*
 Checks all items in array on uniqueness.

 @require $Typeof(arr)::kind == SLICE : "Must be a slice"
*>
macro bool array_check_uniq(arr) => _array_check_uniq{$Typeof(arr[0])}(arr);

<*
 Checks all items in array on uniqueness.

 @require types::is_equatable_type(CheckUniqItem) : "Must be equatable type"
*>
fn bool _array_check_uniq(CheckUniqItem[] arr) <CheckUniqItem> @local
{
	for (sz i = 0; i < arr.len; ++i)
	{
		CheckUniqItem* item = &arr[i];
		for (sz j = 0; j < arr.len; ++j)
		{
			if (j != i && *item == arr[j]) return false;
		}
	}
	return true;
}

<*
 Performs wrapping increment over runtime boundary.
 Boundary is excluded from range. (max value == boundary - 1)

 @require types::is_int($Typeof(value)) : "Must be an int"
 @require types::is_int($Typeof(boundary)) : "Must be an int"
*>
macro wrap_inc(value, boundary)
{
	return value == boundary - 1 ? 0 : value + 1;
}

<*
 Compile time version.
 Performs wrapping increment over compile time boundary.
 Boundary is excluded from range. (max value == boundary - 1)

 @require types::is_int($Typeof(value)) : "Must be an int"
 @require types::is_int($Typeof($boundary)) : "Must be an int"
*>
macro @wrap_inc(value, $boundary) @builtin
{
	$if math::@is_power_of_2($boundary):
		return value + 1 & ($boundary - 1);
	$else
		return value == $boundary - 1 ? 0 : value + 1;
	$endif
}
