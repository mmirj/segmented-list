//! A growable list of items in memory with indexed access.
//!
//! Allocating additional memory never invalidates existing element pointers.
//! Elements are not guaranteed to be contiguous. For that, use `std.ArrayList`.

// Derived from Zig's former std.SegmentedList.
// Source: https://codeberg.org/ziglang/zig/src/tag/0.15.2/lib/std/segmented_list.zig

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// A growable list of `T` with indexed access.
///
/// Allocating additional memory never invalidates existing element pointers.
/// `inline_capacity` must be 0 or a power of 2.
/// Dynamic segments double in size.
/// Indexed access and pop are O(1), append is amortized O(1), and iteration is O(n).
/// The same allocator must be used throughout the list's lifetime.
/// Initialize directly with `.empty` and deinitialize with `deinit`.
///
/// Only `len` is intended for direct access.
/// A list that has allocated memory must not be copied.
/// The list must not be moved while a pointer to an inline element is in use.
/// `deinit` does not deinitialize the elements.
pub fn SegmentedList(comptime T: type, comptime inline_capacity_value: usize) type {
    comptime {
        if (inline_capacity_value != 0 and !std.math.isPowerOfTwo(inline_capacity_value)) {
            @compileError("inline_capacity must be zero or a power of two");
        }
    }

    return struct {
        const Self = @This();
        const usize_bit_count: usize = @bitSizeOf(usize);
        const inline_exponent: usize = if (inline_capacity_value == 0)
            0
        else
            @intCast(std.math.log2_int(usize, inline_capacity_value));
        const segment_count_max = usize_bit_count - inline_exponent;

        inline_items: [inline_capacity_value]T = undefined,
        segment_directory: [][*]T = &.{},
        segment_count: usize = 0,

        /// The number of items in the list.
        /// Modify only through the list operations.
        len: usize = 0,

        const Location = struct {
            segment_index: usize,
            item_index: usize,
        };

        /// A list containing no elements and no allocated memory.
        pub const empty: Self = .{};

        /// The maximum number of items stored directly in the list.
        pub const inline_capacity = inline_capacity_value;

        pub const Iterator = BaseIterator(*Self, *T);
        pub const ConstIterator = BaseIterator(*const Self, *const T);

        /// Release all allocated memory and leave the list in an undefined state.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            free_segment_range(allocator, self.segment_directory, self.segment_count, 0);
            allocator.free(self.segment_directory);
            self.* = undefined;
        }

        /// Returns how many `T` values the list can hold without allocating additional memory.
        /// Zero-sized elements report `maxInt(usize)`.
        pub fn capacity(self: *const Self) usize {
            if (@sizeOf(T) == 0) return std.math.maxInt(usize);
            assert(self.segment_count <= segment_count_max);

            if (self.segment_count == segment_count_max) {
                return std.math.maxInt(usize);
            }
            if (inline_capacity_value == 0) {
                const capacity_plus_one: usize = @as(usize, 1) <<
                    @intCast(self.segment_count);
                return capacity_plus_one - 1;
            }
            return inline_capacity_value << @intCast(self.segment_count);
        }

        /// Modify the list so that it can hold at least `minimum` items.
        /// Never invalidates element pointers.
        /// Allocation failure leaves the list unchanged.
        pub fn ensureTotalCapacity(
            self: *Self,
            allocator: Allocator,
            minimum: usize,
        ) Allocator.Error!void {
            if (minimum <= self.capacity()) return;
            try self.grow_segments(allocator, segment_count_for_minimum(minimum));
        }

        /// Modify the list so that it can hold at least `additional_count` more items.
        /// Never invalidates element pointers.
        pub fn ensureUnusedCapacity(
            self: *Self,
            allocator: Allocator,
            additional_count: usize,
        ) Allocator.Error!void {
            const minimum = std.math.add(usize, self.len, additional_count) catch {
                return error.OutOfMemory;
            };
            try self.ensureTotalCapacity(allocator, minimum);
        }

        /// Extend the list by 1 element. Allocates more memory as necessary.
        /// Never invalidates element pointers.
        pub fn append(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            const item_pointer = try self.addOne(allocator);
            item_pointer.* = item;
        }

        /// Extend the list by 1 element.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.addOneAssumeCapacity().* = item;
        }

        /// Append the slice of items to the list. Allocates more memory as necessary.
        /// Never invalidates element pointers.
        /// Allocation failure leaves the list unchanged.
        pub fn appendSlice(
            self: *Self,
            allocator: Allocator,
            items: []const T,
        ) Allocator.Error!void {
            try self.ensureUnusedCapacity(allocator, items.len);
            self.appendSliceAssumeCapacity(items);
        }

        /// Append the slice of items to the list.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold the additional items.
        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            assert(items.len <= self.capacity() - self.len);
            if (@sizeOf(T) == 0) {
                self.len += items.len;
                return;
            }

            var source_index: usize = 0;
            var destination_index = self.len;
            while (source_index < items.len) {
                const destination = self.segment_tail(destination_index);
                const count = @min(destination.len, items.len - source_index);
                @memcpy(destination[0..count], items[source_index..][0..count]);
                source_index += count;
                destination_index += count;
            }
            self.len = destination_index;
        }

        /// Increase length by 1, returning a pointer to the new item.
        /// The new item has an `undefined` value.
        /// Never invalidates existing element pointers.
        pub fn addOne(self: *Self, allocator: Allocator) Allocator.Error!*T {
            const new_len = std.math.add(usize, self.len, 1) catch return error.OutOfMemory;
            try self.ensureTotalCapacity(allocator, new_len);
            return self.addOneAssumeCapacity();
        }

        /// Increase length by 1, returning a pointer to the new item.
        /// The new item has an `undefined` value.
        /// Never invalidates existing element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn addOneAssumeCapacity(self: *Self) *T {
            assert(self.len < self.capacity());
            const index = self.len;
            const item_pointer = self.unchecked_at(index);
            self.len = index + 1;
            return item_pointer;
        }

        /// Adjust the list length to `new_len`.
        /// Additional elements contain the value `undefined`.
        /// Growing never invalidates element pointers.
        /// Shrinking invalidates pointers to elements at indexes `new_len` and beyond.
        pub fn resize(self: *Self, allocator: Allocator, new_len: usize) Allocator.Error!void {
            if (new_len > self.len) try self.ensureTotalCapacity(allocator, new_len);
            self.len = new_len;
        }

        /// Remove and return the last element from the list.
        /// If the list is empty, returns `null`.
        /// Invalidates pointers to the last element.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const index = self.len - 1;
            const item = self.unchecked_at(index).*;
            self.len = index;
            return item;
        }

        /// Reduce length to `new_len`.
        /// Invalidates pointers to elements at indexes `new_len` and beyond.
        /// Keeps capacity the same.
        /// Asserts that the new length is less than or equal to the previous length.
        pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= self.len);
            self.len = new_len;
        }

        /// Reduce length to `new_len` and release every complete unused element segment.
        /// The segment directory may remain allocated if the allocator cannot shrink it.
        /// Invalidates pointers to elements at indexes `new_len` and beyond.
        /// Pointers to retained elements remain valid.
        /// Asserts that the new length is less than or equal to the previous length.
        pub fn shrinkAndFree(self: *Self, allocator: Allocator, new_len: usize) void {
            assert(new_len <= self.len);
            const retained_segment_count = segment_count_for_minimum(new_len);

            self.len = new_len;
            free_segment_range(
                allocator,
                self.segment_directory,
                self.segment_count,
                retained_segment_count,
            );
            self.segment_count = retained_segment_count;
            self.shrink_segment_directory(allocator);
        }

        /// Reduce length to 0.
        /// Invalidates all element pointers.
        /// Keeps capacity the same.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        /// Release all allocated memory and reduce length to 0.
        /// Invalidates all element pointers.
        pub fn clearAndFree(self: *Self, allocator: Allocator) void {
            free_segment_range(allocator, self.segment_directory, self.segment_count, 0);
            allocator.free(self.segment_directory);
            self.* = .empty;
        }

        /// Return a pointer to the item at `index`.
        /// Asserts that the index is in bounds.
        pub fn at(self: anytype, index: usize) ElementPointer(@TypeOf(self)) {
            assert(index < self.len);
            return self.unchecked_at(index);
        }

        /// Copy `destination.len` elements starting at `start_index` into `destination`.
        /// The source and destination memory must not overlap.
        /// Asserts that the source range is in bounds.
        pub fn copyToSlice(
            self: *const Self,
            destination: []T,
            start_index: usize,
        ) void {
            assert(start_index <= self.len);
            assert(destination.len <= self.len - start_index);
            if (@sizeOf(T) == 0) return;

            var source_index = start_index;
            var destination_index: usize = 0;
            while (destination_index < destination.len) {
                const source = self.segment_tail(source_index);
                const count = @min(source.len, destination.len - destination_index);
                @memcpy(destination[destination_index..][0..count], source[0..count]);
                source_index += count;
                destination_index += count;
            }
        }

        /// Return a mutable iterator positioned at `start_index`.
        /// The first call to `next` returns the item at `start_index`.
        /// Asserts that `start_index <= len`.
        /// Do not move the list or change its length or capacity while the iterator is in use.
        pub fn iterator(self: *Self, start_index: usize) Iterator {
            assert(start_index <= self.len);
            return Iterator.init(self, start_index);
        }

        /// Return a const iterator positioned at `start_index`.
        /// The first call to `next` returns the item at `start_index`.
        /// Asserts that `start_index <= len`.
        /// Do not move the list or change its length or capacity while the iterator is in use.
        pub fn constIterator(self: *const Self, start_index: usize) ConstIterator {
            assert(start_index <= self.len);
            return ConstIterator.init(self, start_index);
        }

        fn grow_segments(
            self: *Self,
            allocator: Allocator,
            required_segment_count: usize,
        ) Allocator.Error!void {
            assert(required_segment_count > self.segment_count);
            assert(required_segment_count <= segment_count_max);

            if (required_segment_count <= self.segment_directory.len) {
                return self.grow_within_directory(allocator, required_segment_count);
            }

            const new_segment_directory = try allocator.alloc(
                [*]T,
                directory_capacity_for_segment_count(required_segment_count),
            );
            errdefer allocator.free(new_segment_directory);
            @memcpy(
                new_segment_directory[0..self.segment_count],
                self.segment_directory[0..self.segment_count],
            );

            var prepared_segment_count = self.segment_count;
            errdefer free_segment_range(
                allocator,
                new_segment_directory,
                prepared_segment_count,
                self.segment_count,
            );
            while (prepared_segment_count < required_segment_count) {
                new_segment_directory[prepared_segment_count] = (try allocator.alloc(
                    T,
                    segment_size(prepared_segment_count),
                )).ptr;
                prepared_segment_count += 1;
            }

            allocator.free(self.segment_directory);
            self.segment_directory = new_segment_directory;
            self.segment_count = required_segment_count;
        }

        fn grow_within_directory(
            self: *Self,
            allocator: Allocator,
            required_segment_count: usize,
        ) Allocator.Error!void {
            const previous_segment_count = self.segment_count;
            var prepared_segment_count = previous_segment_count;
            errdefer free_segment_range(
                allocator,
                self.segment_directory,
                prepared_segment_count,
                previous_segment_count,
            );

            while (prepared_segment_count < required_segment_count) {
                self.segment_directory[prepared_segment_count] = (try allocator.alloc(
                    T,
                    segment_size(prepared_segment_count),
                )).ptr;
                prepared_segment_count += 1;
            }
            self.segment_count = required_segment_count;
        }

        fn shrink_segment_directory(self: *Self, allocator: Allocator) void {
            if (self.segment_count == self.segment_directory.len) return;
            if (self.segment_count == 0) {
                allocator.free(self.segment_directory);
                self.segment_directory = &.{};
                return;
            }
            if (allocator.resize(self.segment_directory, self.segment_count)) {
                self.segment_directory = self.segment_directory[0..self.segment_count];
            }
        }

        fn free_segment_range(
            allocator: Allocator,
            segment_directory: [][*]T,
            allocated_segment_count: usize,
            retained_segment_count: usize,
        ) void {
            assert(retained_segment_count <= allocated_segment_count);
            assert(allocated_segment_count <= segment_directory.len);

            var segment_index = allocated_segment_count;
            while (segment_index > retained_segment_count) {
                segment_index -= 1;
                allocator.free(
                    segment_directory[segment_index][0..segment_size(segment_index)],
                );
            }
        }

        fn segment_count_for_minimum(minimum: usize) usize {
            if (@sizeOf(T) == 0 or minimum <= inline_capacity_value) return 0;

            var element_capacity: usize = inline_capacity_value;
            var required_segment_count: usize = 0;
            while (element_capacity < minimum) {
                const next_segment_size = segment_size(required_segment_count);
                required_segment_count += 1;
                element_capacity = std.math.add(
                    usize,
                    element_capacity,
                    next_segment_size,
                ) catch {
                    // This segment count can hold any `usize` length.
                    return required_segment_count;
                };
            }
            return required_segment_count;
        }

        fn segment_size(segment_index: usize) usize {
            assert(segment_index < segment_count_max);
            const first_segment_size: usize = if (inline_capacity_value == 0)
                1
            else
                inline_capacity_value;
            return first_segment_size << @intCast(segment_index);
        }

        fn directory_capacity_for_segment_count(required_segment_count: usize) usize {
            assert(required_segment_count > 0);
            assert(required_segment_count <= segment_count_max);
            return std.math.ceilPowerOfTwoAssert(usize, required_segment_count);
        }

        fn segment_location(index: usize) Location {
            assert(index >= inline_capacity_value);
            if (inline_capacity_value == 0) {
                const adjusted_index = index + 1;
                const segment_index: usize = @intCast(std.math.log2_int(usize, adjusted_index));
                const segment_start = (@as(usize, 1) << @intCast(segment_index)) - 1;
                return .{ .segment_index = segment_index, .item_index = index - segment_start };
            }

            const segment_index = @as(usize, @intCast(std.math.log2_int(usize, index))) -
                inline_exponent;
            const segment_start = inline_capacity_value << @intCast(segment_index);
            return .{ .segment_index = segment_index, .item_index = index - segment_start };
        }

        // Requires `index < capacity()`.
        fn unchecked_at(self: anytype, index: usize) ElementPointer(@TypeOf(self)) {
            if (@sizeOf(T) == 0) return zero_sized_item_pointer(ElementPointer(@TypeOf(self)));
            if (index < inline_capacity_value) return &self.inline_items[index];

            const location = segment_location(index);
            return &self.segment_directory[location.segment_index][location.item_index];
        }

        // The returned slice may include unused capacity.
        fn segment_tail(self: anytype, index: usize) ElementSlice(@TypeOf(self)) {
            if (index < inline_capacity_value) return self.inline_items[index..];
            const location = segment_location(index);
            const remaining = segment_size(location.segment_index) - location.item_index;
            const segment = self.segment_directory[location.segment_index];
            return segment[location.item_index..][0..remaining];
        }

        fn ElementPointer(comptime SelfPointer: type) type {
            const pointer_info = @typeInfo(SelfPointer).pointer;
            return if (pointer_info.is_const) *const T else *T;
        }

        fn ElementSlice(comptime SelfPointer: type) type {
            const pointer_info = @typeInfo(SelfPointer).pointer;
            return if (pointer_info.is_const) []const T else []T;
        }

        fn zero_sized_item_pointer(comptime ItemPointer: type) ItemPointer {
            const address = comptime std.mem.alignBackward(usize, std.math.maxInt(usize), @alignOf(T));
            return @ptrFromInt(address);
        }

        fn BaseIterator(comptime ListPointer: type, comptime ItemPointer: type) type {
            return struct {
                list: ListPointer,
                index: usize,
                segment_index: usize,
                item_index: usize,

                fn init(list: ListPointer, index: usize) @This() {
                    var segment_index: usize = 0;
                    var item_index: usize = 0;
                    if (@sizeOf(T) != 0 and index >= inline_capacity_value) {
                        if (index == list.capacity()) {
                            segment_index = list.segment_count;
                        } else {
                            const location = segment_location(index);
                            segment_index = location.segment_index;
                            item_index = location.item_index;
                        }
                    }
                    return .{
                        .list = list,
                        .index = index,
                        .segment_index = segment_index,
                        .item_index = item_index,
                    };
                }

                /// Return the next element and advance the iterator.
                pub fn next(self: *@This()) ?ItemPointer {
                    if (self.index >= self.list.len) return null;
                    if (@sizeOf(T) == 0) {
                        self.index += 1;
                        return zero_sized_item_pointer(ItemPointer);
                    }
                    if (self.index < inline_capacity_value) {
                        const item_pointer = &self.list.inline_items[self.index];
                        self.index += 1;
                        return item_pointer;
                    }

                    const segment = self.list.segment_directory[self.segment_index];
                    const item_pointer = &segment[self.item_index];
                    self.index += 1;
                    self.item_index += 1;
                    if (self.item_index == segment_size(self.segment_index)) {
                        self.segment_index += 1;
                        self.item_index = 0;
                    }
                    return item_pointer;
                }

                /// Move the iterator backward and return the previous element.
                pub fn prev(self: *@This()) ?ItemPointer {
                    if (self.index == 0) return null;
                    self.index -= 1;
                    if (@sizeOf(T) == 0) return zero_sized_item_pointer(ItemPointer);
                    if (self.index < inline_capacity_value) {
                        return &self.list.inline_items[self.index];
                    }
                    if (self.item_index == 0) {
                        self.segment_index -= 1;
                        self.item_index = segment_size(self.segment_index);
                    }
                    self.item_index -= 1;
                    return &self.list.segment_directory[self.segment_index][self.item_index];
                }
            };
        }
    };
}
