module arena_test @test;

import ext::allocators::arena;
import std::collections::map;
import std::collections::list;

fn void sequential_alloc_free()
{
	ThreadArena* arena = arena::create();
	defer arena.free();
	Allocator a = (Allocator)arena;

	DString s1;
	s1.init(a, 8);
	char[] bytes1 = "hello_world hello_world hello_world hello_world!";
	s1.append_bytes(bytes1);
	test::eq(s1.str_view(), bytes1);
	s1.free();

	DString s2;
	char[] bytes2 = "this is the SECOND phrase!";
	s2.init(a, 256);
	s2.append_bytes(bytes2);
	test::eq(s2.str_view(), bytes2);
	s2.free();

	DString s3;
	char[] bytes3 = "this is the THIRD phrase!";
	s3.init(a, 412);
	s3.append_bytes(bytes3);
	test::eq(s3.str_view(), bytes3);
	s3.free();
}

fn void mem_zero()
{
	ThreadArena* arena = arena::create();
	defer arena.free();
	Allocator a = (Allocator)arena;

	char[] a1 = alloc::new_array(a, char, 256);
	char[] a2 = alloc::new_array(a, char, 256);
	char[] a3 = alloc::new_array(a, char, 256);

	foreach (el : a1)
	{
		test::eq(el, 0);
	}
	foreach (el : a2)
	{
		test::eq(el, 0);
	}
	foreach (el : a3)
	{
		test::eq(el, 0);
	}

	alloc::free(a, a1);
	alloc::free(a, a2);
	alloc::free(a, a3);
}

fn void test_list()
{
	ThreadArena* arena = arena::create();
	defer arena.free();
	Allocator a = (Allocator)arena;

	char[100] bytes @noinit;
	fill_random_ascii(bytes[..]);

	List{char} l;
	l.init(a, 64);
	defer l.free();

	char[] a1 = alloc::alloc_array(a, char, 100);
	l.push_all(a1);
	test::eq(l.entries[:100], a1);
	
	char[] a2 = alloc::alloc_array(a, char, 100);
	l.push_all(a2);
	test::eq(l.entries[100:100], a2);

	char[] a3 = alloc::alloc_array(a, char, 1000);
	l.push_all(a3);
	test::eq(l.entries[1000:200], a3[800:200]);
}

fn void test_map()
{
	ThreadArena* arena = arena::create();
	defer arena.free();
	Allocator a = (Allocator)arena;

	HashMap{String, int} m;
	m.init(a);
	defer m.free();

	m.set("hello", 13);
	m.set("world", 476);
	m.set("key", 1000);
	m.set("val", 777);

	test::eq(m.get("hello")!!, 13);
	test::eq(m.get("world")!!, 476);
	test::eq(m.get("key")!!, 1000);
	test::eq(m.get("val")!!, 777);

	m.remove("hello")!!;
	m.remove("world")!!;
	m.remove("key")!!;
	m.remove("val")!!;
}

fn void test_dstring()
{
	ThreadArena* arena = arena::create();
	defer arena.free();
	Allocator a = (Allocator)arena;

	DString s1;
	s1.init(a, 512);
	char[*] bytes1 = "hello_world hello_world hello_world hello_world!";
	s1.append_bytes(bytes1[..]);
	test::eq(s1.str_view()[:bytes1.len], bytes1[..]);

	DString s2;
	s2.init(a, 256);
	char[*] bytes2 = "this is the SECOND phrase!";
	s2.append_bytes(bytes2[..]);
	test::eq(s2.str_view()[:bytes2.len], bytes2[..]);

	DString s3;
	s3.init(a, 412);
	char[*] bytes3 = "this is the THIRD phrase!";
	s3.append_bytes(bytes3[..]);
	test::eq(s3.str_view()[:bytes3.len], bytes3[..]);

	DString s4;
	s4.init(a, 1024);
	char[*] bytes4 = "this is the FOURTH phrase!";
	s4.append_bytes(bytes4[..]);
	test::eq(s4.str_view()[:bytes4.len], bytes4[..]);
}

fn void temp_scope()
{
	Arena* arena = arena::create(mem);
	defer arena.free();
	Allocator a = arena;

	arena.@temp_scope_alloc(; alloc)
	{
		char[] mem1 = alloc::alloc_array(alloc, char, 200);
		fill_alloc(mem1);
		log_alloc(mem1, "mem1");

		char[] mem2 = alloc::alloc_array(alloc, char, 200);
		fill_alloc(mem2);
		log_alloc(mem2, "mem2");

		char[] mem3 = alloc::alloc_array(alloc, char, 200);
		fill_alloc(mem3);
		log_alloc(mem3, "mem3");

		char[] mem4 = alloc::alloc_array(alloc, char, 200);
		fill_alloc(mem4);
		log_alloc(mem4, "mem4");
	};
}

fn void test_aligned_allocations()
{
	Arena* arena = arena::create(mem);
	defer arena.free();
	Allocator a = arena;

	int128[] a1 = alloc::alloc_array_aligned(a, int128, 15);
	ushort[] a2 = alloc::alloc_array_aligned(a, ushort, 120);
	ulong[] a3 = alloc::alloc_array_aligned(a, ulong, 38);
	char[] a4 = alloc::alloc_array_aligned(a, char, 512);
	int128[] a5 = alloc::alloc_array_aligned(a, int128, 14);

	int128[*] buf1 = { 1, 2, 3, 4, 6, 7, 8, 9, 10 };
	ushort[*] buf2 = { 1, 2, 3, 4, 6, 7, 8, 9, 10 };
	ulong[*] buf3 = { 1, 2, 3, 4, 6, 7, 8, 9, 10 };
	char[*] buf4 = { 1, 2, 3, 4, 6, 7, 8, 9, 10 };
	int128[*] buf5 = { 1, 2, 3, 4, 6, 7, 8, 9, 10 };

	a1[:buf1.len] = buf1[..];
	test::eq(a1[:buf1.len], buf1[..]);

	a2[:buf2.len] = buf2[..];
	test::eq(a2[:buf2.len], buf2[..]);

	a3[:buf3.len] = buf3[..];
	test::eq(a3[:buf3.len], buf3[..]);

	a4[:buf4.len] = buf4[..];
	test::eq(a4[:buf4.len], buf4[..]);

	a5[:buf5.len] = buf5[..];
	test::eq(a5[:buf5.len], buf5[..]);

	alloc::free(a, a1);
	alloc::free(a, a2);
	alloc::free(a, a3);
	alloc::free(a, a4);
	alloc::free(a, a5);
}

fn void single_alloc_filling_entire_buf()
{
	Arena* arena = arena::create(mem);
	defer arena.free();
	Allocator a = arena;

	char[100] bytes @noinit;
	fill_random_ascii(bytes[..]);

	char[] a1 = alloc::alloc_array(a, char, 2000);
	a1[1900:100] = bytes[..];
	test::eq(a1[1900:100], bytes[..]);

	alloc::free(a, a1);
}

// Helpers

module arena_test;
import std::math::random;
import std::io;

fn void fill_alloc(char[] alloc)
{
	int rn = random::rand(128);
	int rn2 = random::rand(128);

	for (int ii = 0; ii < alloc.len; ++ii)
	{
		alloc[ii] = (ii & 1) == 0 ? (char)rn : (char)rn2;
	}
}

fn void fill_random_ascii(char[] buf)
{
	foreach (&c : buf)
	{
		*c = (char)(random::rand('z' - 'a') + 'a');
	}
}

fn void log_alloc(char[] alloc, String name = "unknown")
{
	io::printfn("Alloc: %s", name);
	for (uint i = 0; i < 3; ++i)
	{
		int r_n = rand(alloc.len);
		io::printf("%c", alloc[r_n]);
	}
	io::printn();
}

