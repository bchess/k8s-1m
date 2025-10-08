// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
#![doc = r#"
A concurrent, block-based growable array (similar to a deque that only supports appending).
Allows random-access get/set in O(1), and amortized O(1) push.

Usage example:

```rust
use mem_etcd::block_deque::BlockDeque;

const BLOCK_SIZE: usize = 8;

fn main() {
    let deque = BlockDeque::<i32, BLOCK_SIZE>::new();

    // Append some numbers
    for i in 0..16 {
        deque.push(i);
    }

    // Get a value (must be Copy, or you could adapt to T: Clone):
    assert_eq!(deque.get(5), Ok(5));
    // Overwrite
    deque.set(5, 999);
    assert_eq!(deque.get(5), Ok(999));

    // Current length
    assert_eq!(deque.len(), 16);
}
"#]

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::RwLock;

/// A concurrent, block-based structure that allows O(1) random access and
/// only supports appending (pushing) at the end.
/// T must be Copy if you want the provided get() method to return a copy
/// of the element by value. If you need to return references or more elaborate
/// lifetimes, you can adapt the code to hold the lock guard.

pub struct BlockDeque<T, const BLOCK_SIZE: usize>
where
    T: Clone,
{
    /// The blocks of this data structure.
    /// Each block is a fixed-size array of Option<T>, so we can differentiate
    /// between used and unused slots in the final block.
    blocks: RwLock<Vec<Box<[Option<T>; BLOCK_SIZE]>>>,
    start_offset: AtomicUsize, // TODO: I don't think this needs to be atomic since it is protected with the blocks write lock

    // The total number of elements currently stored (not the number of blocks).
    length: AtomicUsize,
}

impl<T, const BLOCK_SIZE: usize> BlockDeque<T, BLOCK_SIZE>
where
    T: Clone,
{
    /// Create a new, empty BlockDeque.
    pub fn new() -> Self {
        Self {
            blocks: RwLock::new(Vec::with_capacity(1)),
            start_offset: AtomicUsize::new(0),
            length: AtomicUsize::new(0),
        }
    }

    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.length.load(Ordering::Acquire)
    }

    pub fn earliest_revision(&self) -> usize {
        self.start_offset.load(Ordering::Acquire)
    }

    pub fn latest_revision(&self) -> usize {
        self.length.load(Ordering::Acquire) + self.start_offset.load(Ordering::Acquire)
    }

    /// Appends a new element to the end of the deque.
    ///
    /// If the last block is full (or doesn't exist), a new block is allocated
    /// under a write lock. Otherwise, only a read lock is taken for the common case.
    pub fn push(&self, value: T) -> usize {
        let index;
        let offset;
        {
            // First, try taking a read lock to see if there's already a block
            // for us to put the element in.
            let blocks_read = self.blocks.read().unwrap();

            let start_offset = self.start_offset.load(Ordering::Acquire);
            index =
                self.length.fetch_add(1, Ordering::AcqRel) + start_offset;
            let block_index = (index / BLOCK_SIZE) - (start_offset / BLOCK_SIZE);
            offset = index % BLOCK_SIZE;

            if block_index < blocks_read.len() {
                // There's already a block ready. Put the element in place.
                // let the_block = &blocks_read[block_index] as *const _ as *mut [Option<T>; BLOCK_SIZE];
                let the_block = blocks_read[block_index].as_ptr() as *mut [Option<T>; BLOCK_SIZE];
                unsafe {
                    (*the_block)[offset] = Some(value);
                }
                return index;
            }
        }

        // We need a new block, so take a write lock.
        let mut blocks_write = self.blocks.write().unwrap();

        // It's possible that a remove_before was called after we released the read lock.
        // index should still be correct, since it wouldn't be valid to remove_before this brand new index.
        // However, previous blocks may have been removed so we need to re-calculate the block index.
        let start_offset = self.start_offset.load(Ordering::Acquire);
        let block_index = (index / BLOCK_SIZE) - (start_offset / BLOCK_SIZE);

        // Add a new block
        while block_index >= blocks_write.len() {
            // Allocate and initialize a Vec directly on the heap
            let mut vec: Vec<Option<T>> = Vec::with_capacity(BLOCK_SIZE);
            vec.resize_with(BLOCK_SIZE, || None);

            let boxed_slice: Box<[Option<T>]> = vec.into_boxed_slice();

            // Convert Vec into a Box<[T]> (heap-allocated slice)
            let boxed_array: Box<[Option<T>; BLOCK_SIZE]> = match boxed_slice.try_into() {
                Ok(array) => array,
                Err(_) => panic!("Size mismatch! The slice does not match the fixed size."),
            };
            blocks_write.push(boxed_array);
        }

        // Now we have a block ready; place the element.
        let the_block = blocks_write[block_index].as_mut_slice();
        the_block[offset] = Some(value);
        index
    }

    /// Replaces the element at the given index with `value` if it exists.
    pub fn set(&self, index: usize, value: T) -> bool
    where
        T: Clone,
    {
        let blocks_read = self.blocks.read().unwrap();

        let current_len = self.length.load(Ordering::Acquire);
        let start_offset = self.start_offset.load(Ordering::Acquire);
        if index >= current_len + start_offset {
            return false;
        }
        if index < start_offset {
            return false;
        }
        let block_index = (index / BLOCK_SIZE) - (start_offset / BLOCK_SIZE);
        let offset = index % BLOCK_SIZE;

        let the_block = blocks_read[block_index].as_ptr() as *mut [Option<T>; BLOCK_SIZE];
        unsafe {
            (*the_block)[offset] = Some(value);
        }
        true
    }

    pub fn get_with<R>(&self, index: usize, f: fn(&Option<T>) -> R)-> R
    where
        T: Clone,
    {
        let blocks_read = self.blocks.read().unwrap();

        let current_len = self.length.load(Ordering::Acquire);
        let start_offset = self.start_offset.load(Ordering::Acquire);
        if index >= current_len + start_offset {
            // Index out of bounds
            return f(&None);
        }

        if index < start_offset {
            // Index out of bounds
            return f(&None);
        }
        let block_index = (index / BLOCK_SIZE) - (start_offset / BLOCK_SIZE);
        let offset = index % BLOCK_SIZE;

        // Safely return a reference to the element if present.
        return f(&blocks_read[block_index][offset]);
    }

    pub fn get(&self, index: usize) -> Result<T, ()>
    where
        T: Clone,
    {
        self.get_with(index, |x| x.clone().ok_or(()))
    }

    pub fn remove_before(&self, idx: usize) -> Result<(), ()> {
        // Print
        let mut blocks_write = self.blocks.write().unwrap();

        let mut start_offset = self.start_offset.load(Ordering::Acquire);
        if idx > start_offset + self.length.load(Ordering::Acquire) {
            return Err(()); // index out of range
        }
        if idx < start_offset {
            return Err(()); // index out of range
        }
        self.length.fetch_sub(idx - start_offset, Ordering::AcqRel);

        let mut i = idx - (start_offset - start_offset % BLOCK_SIZE);
        while i >= BLOCK_SIZE {
            blocks_write.remove(0);
            i -= BLOCK_SIZE;
            start_offset = 0;
        }
        if i > 0 {
            let the_block = blocks_write.first_mut().unwrap();
            the_block[start_offset % BLOCK_SIZE..i].fill(None);
        }
        self.start_offset.store(idx, Ordering::Release);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_test() {
        const BLOCK_SIZE: usize = 4;
        let deque = BlockDeque::<i32, BLOCK_SIZE>::new();

        // Push values 0..8
        for i in 16..24 {
            deque.push(i);
        }
        assert_eq!(deque.len(), 8);

        // Check gets
        for i in 0..8 {
            assert_eq!(deque.get(i), Ok(i as i32 + 16));
        }
        // No value at index 8
        assert_eq!(deque.get(8), Err(()));

        // Set a new value
        deque.set(3, 999);
        assert_eq!(deque.get(3), Ok(999));
    }

    #[test]
    fn remove_before_test_one_block() {
        const BLOCK_SIZE: usize = 4;
        let deque = BlockDeque::<i32, BLOCK_SIZE>::new();

        deque.push(1);
        deque.push(2);
        assert_eq!(deque.remove_before(1), Ok(()));
        assert_eq!(deque.len(), 1);
        assert_eq!(deque.get(0), Err(()));
        assert_eq!(deque.get(1), Ok(2));
    }

    #[test]
    fn remove_before_test_two_blocks() {
        const BLOCK_SIZE: usize = 4;
        let deque = BlockDeque::<i32, BLOCK_SIZE>::new();

        for i in 0..11 {
            deque.push(i);
        }
        assert_eq!(deque.len(), 11);
        assert_eq!(deque.remove_before(10), Ok(()));
        assert_eq!(deque.len(), 1);
        assert_eq!(deque.get(10), Ok(10));

        deque.push(11);
        deque.push(12);
        deque.push(13);
        assert_eq!(deque.get(10), Ok(10));
        assert_eq!(deque.get(11), Ok(11));
        assert_eq!(deque.get(12), Ok(12));
        assert_eq!(deque.get(13), Ok(13));

        assert_eq!(deque.remove_before(12), Ok(()));
        assert_eq!(deque.len(), 2);
        assert_eq!(deque.get(12), Ok(12));
        assert_eq!(deque.get(13), Ok(13));
    }

    #[test]
    fn remove_before_test_across_blocks() {
        const BLOCK_SIZE: usize = 10;
        let deque = BlockDeque::<i32, BLOCK_SIZE>::new();

        for i in 0..15 {
            deque.push(i);
        }

        deque.remove_before(9).unwrap();
        deque.remove_before(13).unwrap();
    }
}
