module std::io::file;
import std::io::path;

enum FileOpenMode
{
	BIN,
	TEXT
}

<*
 Opens the file in read mode.
*>
fn File? open_read(Path path, FileOpenMode mode)
{
	String opts = mode == BIN ? "r+b" : "r+t";
	return open_path(path, opts);
}

<*
 Opens the file in write mode.
*>
fn File open_write(Path path, FileOpenMode mode)
{
	String opts = mode == BIN ? "w+b" : "w+t";
	return open_path(path, opts)!!;
}

<*
 Opens and reads the file, allocates a sufficient buffer.
*>
fn char[]? read_entire(Allocator alloc, Path file_path, FileOpenMode mode = BIN)
{
	File file = open_read(file_path, mode)!;
	sz file_size = file.size()!;
	char[] buff = alloc::alloc_array(alloc, char, file_size);
	file.read_all_buff(buff);
	return buff;
}

<*
 Opens and reads the file into user provided buffer.
*>
fn sz? read_entire_to_buff(Path file_path, char[] buff, FileOpenMode mode = BIN)
{
	File file = open_read(file_path, mode)!;
	sz file_size = file.size()!;
	assert(buff.len == file_size, "Should be enough space in the buffer");
	sz read = file.read_all_buff(buff);
	return read;
}

<*
 Writes to the file all contents of 'buff' with loop.
*>
fn void File.write_all(&file, char[] buff)
{
	sz written = 0;
	while (written < buff.len)
	{
		written += file.write(buff[written..buff.len - 1])!!;
	}
}

<*
 Allocates sufficient buffer, reads file to it, and returns it to the user.
 Caller is responsible for freeing returned memory.
*>
fn char[] File.read_all(&file, Allocator alloc, sz* out_read_bytes = null)
{
	sz file_len = file.size()!!;
	sz read = 0;

	char[] buff = alloc::alloc_array(alloc, char, file_len);
	defer catch alloc::free(alloc, buff.ptr);

	while (read < buff.len)
	{
		read += file.read(buff[read..buff.len-1])!!;
	}

	if (out_read_bytes)
	{
		*out_read_bytes = read;
	}
	return buff;
}

<*
 Reads the file into user provided buffer.

 @require buff.len == file.size()!! : "Should be enough space in the buffer"
*>
fn sz File.read_all_buff(&file, char[] buff)
{
	sz read = 0;
	while (read < buff.len)
	{
		sz curr_read = file.read(buff[read..buff.len-1])!!;
		if (!curr_read)
		{
			return read;
		}
		read += curr_read;
	}
	return read;
}

module std::io::path;

<*
 Gives a base name without extension:
 /home/user/dir/program.c++ -> program
*>
fn String Path.basename_no_ext(&self)
{
	String basename = self.basename();
	sz index = basename.rindex_of(".") ?? basename.len;
	return basename[:index];
}
