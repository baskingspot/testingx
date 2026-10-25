//! The linker symbol a function pointer belongs to.
//!
//! DWARF knows the source name (`benchmarkThing`). The linker kept
//! `bench.benchmarkThing`, and that is the name `nm`, `perf`, and objdump
//! agree on. The symtab is the only place with both the linkage name and the
//! size, so read it directly instead of asking DWARF and guessing the prefix.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const elf = std.elf;

pub const Symbol = struct {
    /// The linkage name, allocated by the caller's allocator.
    name: []const u8,
    /// Link-time virtual address, the space objdump and perf use.
    address: u64,
    size: u64,

    pub fn end(self: Symbol) u64 {
        return self.address + self.size;
    }
};

pub const Error = error{
    NotElf,
    UnsupportedElfClass,
    NoSymtab,
    SymbolNotFound,
    InvalidFile,
};

/// Find the function symbol containing `vaddr` in the ELF file at `path`.
/// `vaddr` is a link-time address: subtract the module slide first.
pub fn lookup(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    vaddr: u64,
) !Symbol {
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);

    if (bytes.len < @sizeOf(elf.Elf64_Ehdr)) return Error.InvalidFile;
    if (!std.mem.eql(u8, bytes[0..elf.MAGIC.len], elf.MAGIC)) return Error.NotElf;
    if (bytes[elf.EI_CLASS] != elf.ELFCLASS64) return Error.UnsupportedElfClass;

    const header: *align(1) const elf.Elf64_Ehdr = @ptrCast(bytes.ptr);
    if (header.e_shentsize != @sizeOf(elf.Elf64_Shdr)) return Error.NoSymtab;
    if (header.e_shoff == 0 or header.e_shnum == 0) return Error.NoSymtab;

    const shdrs = try sliceOf(elf.Elf64_Shdr, bytes, header.e_shoff, header.e_shnum);

    var symtab: ?elf.Elf64_Shdr = null;
    for (shdrs) |shdr| {
        if (shdr.sh_type == elf.SHT_SYMTAB) {
            symtab = shdr;
            break;
        }
    }
    const tab = symtab orelse return Error.NoSymtab;
    if (tab.sh_link >= shdrs.len) return Error.NoSymtab;

    const strtab = shdrs[tab.sh_link];
    if (tab.sh_entsize != @sizeOf(elf.Elf64_Sym)) return Error.NoSymtab;
    if (tab.sh_entsize == 0) return Error.NoSymtab;

    const symbols = try sliceOf(elf.Elf64_Sym, bytes, tab.sh_offset, tab.sh_size / tab.sh_entsize);
    const strings = try byteRange(bytes, strtab.sh_offset, strtab.sh_size);

    var best: ?elf.Elf64_Sym = null;
    for (symbols) |symbol| {
        if (symbol.st_shndx == elf.SHN_UNDEF) continue;
        if (symbol.st_value > vaddr) continue;
        if (vaddr >= symbol.st_value + symbol.st_size) continue;
        if (symbol.st_name >= strings.len) continue;
        // A zero-size or data symbol tells us nothing about a function.
        if (symbol.st_type() != elf.STT_FUNC) continue;

        if (best == null or symbol.st_value > best.?.st_value) best = symbol;
    }

    const symbol = best orelse return Error.SymbolNotFound;
    return .{
        .name = try allocator.dupe(u8, std.mem.sliceTo(strings[symbol.st_name..], 0)),
        .address = symbol.st_value,
        .size = symbol.st_size,
    };
}

fn readFile(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn byteRange(bytes: []const u8, offset: u64, size: u64) Error![]const u8 {
    const start = std.math.cast(usize, offset) orelse return Error.InvalidFile;
    const len = std.math.cast(usize, size) orelse return Error.InvalidFile;
    if (start > bytes.len or len > bytes.len - start) return Error.InvalidFile;
    return bytes[start..][0..len];
}

fn sliceOf(
    comptime T: type,
    bytes: []const u8,
    offset: u64,
    count: u64,
) Error![]align(1) const T {
    const raw = try byteRange(bytes, offset, count * @sizeOf(T));
    if (raw.len % @sizeOf(T) != 0) return Error.InvalidFile;
    const ptr: [*]align(1) const T = @ptrCast(raw.ptr);
    return ptr[0 .. raw.len / @sizeOf(T)];
}

test "lookup finds this test binary's own symbol" {
    if (comptime builtin.object_format == .elf) {
        const info = std.debug.getSelfDebugInfo() catch return error.SkipZigTest;
        const address = @intFromPtr(&lookup);
        const slide = info.getModuleSlide(std.testing.io, address) catch return error.SkipZigTest;
        const path = info.getModuleName(std.testing.io, address) catch return error.SkipZigTest;

        const symbol = try lookup(std.testing.allocator, std.testing.io, path, address - slide);
        defer std.testing.allocator.free(symbol.name);
        try std.testing.expect(std.mem.endsWith(u8, symbol.name, "lookup"));
        try std.testing.expect(symbol.size > 0);
    } else return error.SkipZigTest;
}
