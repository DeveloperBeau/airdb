/// An absolute byte offset into the mapped file: the stable identity of every
/// stored node.
pub const Reference = u64;
/// The reserved "no node" reference; offset 0 is the file header, never a node.
pub const nullReference: Reference = 0;
