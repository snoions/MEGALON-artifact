// change these numbers to change where to allocate log memory / put replicas

// whether NUMA_MEM may also be an execution node (see EXEC_ON_MEM in src/common/constants.h;
// the two must match): the execution nodes are then nodes 0 .. NUM_EXEC - 1
pub const EXEC_ON_MEM: bool = false;

// hardware numa memory node
pub const NUMA_MEM: u64 = 0;

// number of hardware numa execution node (where replicas are allocated)
pub const NUM_EXEC: usize = 3;

/**
 * number of logical node (replicas) that shares the cxl memory
 * there is a round robin assignment of replicas to hardware numa execution node
 */
pub const LOGICAL_NODE_NUM: usize = 3;

// KEY_SIZE determines which BlockId definition to use
// KEY_SIZE == 24: use BlockId with server_id, inode, offset (blockid_file.h)
// KEY_SIZE != 24: use BlockId with only offset + padding (blockid_variable.h)
pub const KEY_SIZE: usize = 24;