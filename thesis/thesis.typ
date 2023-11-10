#import "template.typ": thesis, bfield, bit, bits, bytes, flagtext, theorem, definition, proof
#import "@preview/codelst:1.0.0": sourcecode

#show: thesis.with(
    title: "verix: A Verified Rust ix(4) driver",
    name: "Henrik Böving",
    email: "henrik_boeving@genua.de",
    matriculation: "XXX",
    abstract: lorem(70),
    paper-size: "a4",
    bibliography-file: "thesis.bib",
    glossary: (
        (key: "NIC", short: "NIC", long: "Network Interface Card"),
        (key: "BMC", short: "BMC", long: "Bounded Model Checking"),
        (key: "CBMC", short: "CBMC", long: "C Bounded Model Checker"),
        (key: "BAR", short: "BAR", long: "Base Address Register"),
        (key: "EBNF", short: "EBNF", long: "Extended Backus Naur Form"),
        (key: "TT", short: "TT", long: "Rust Token Tree"),
        (key: "IPC", short: "IPC", long: "Inter Process Communication"),
        (key: "DMA", short: "DMA", long: "Direct Memory Access"),
        (key: "MMU", short: "MMU", long: "Memory Management Unit"),
        (key: "IOMMU", short: "IOMMU", long: "Input/Output Memory Management Unit"),
        (key: "VBus", short: "VBus", long: "Virtual Bus"),
        (key: "MMIO", short: "MMIO", long: "Memory Mapped Input/Output"),
        (key: "WG", short: "WG", long: "Working Group"),
        (key: "MTU", short: "MTU", long: "Maximum Transmission Unit"),
        (key: "OOM", short: "OOM", long: "Out Of Memory"),
        (key: "Mpps", short: "Mpps", long: "Mega packets per second")
    ),
    supervisor_institution: "Prof. Dr. Matthias Güdemann (HM)",
    supervisor_company: "Claas Lorenz (genua GmbH)",
    institution: "University of Applied Sciences Munich (HM)\nFaculty for Computer Science and Mathematics",
    logo_company: "figures/genua.svg",
    logo_institution: "figures/hm.svg",
    logo_size: 60%,
    submition_date: "DD.MM.2024"
)

= Introduction
// Inspired by: https://grosser.science/howtos/paper-writing
// Introduction. In one sentence, what’s the topic?
As computer systems are becoming increasingly omnipresent and complex both the negative impact of bugs as well as the likelihood of them occurring are increasing.
Because of this, catching bugs with potentially catastrophic effects before they happen is becoming more and more important.
These bugs usually occur in one of two fashions:
1. Processing of data, for example in algorithm or data structure implementations
2. Acquisition of data, usually when interacting with the outside world in some way or form
This thesis is mostly concerned with the latter kind.

// State the problem you tackle
Networking represents a key interaction point with the outside world for most current computer systems, it usually involves three key components:
- the @NIC driver
- the network stack
- networking application
While verifying network stacks and applications requires substantial resources due to their complexity, verification of @NIC drivers is much more approachable since they have only two jobs:
1. Setting up the @NIC
2. Handling the receiving and transmission of packets.

// Summarize why nobody else has adequately answered the research question yet.
To our knowledge, there do not exist network drivers whose interaction with the @NIC itself has been formally verified.
Instead, the focus is usually put on other issues that arise in driver implementation:
- #cite(<witowski2007drivers>) and #cite(<ball2004slam>) are mostly concerned with the driver interactions with the rest of the kernel
  as well as the absence of C-related issues
- #cite(<more2021hol4drivers>) implements a verified monitor for interactions of a real driver with the @NIC instead of verifying the driver itself.
   While this means that bad interactions with the hardware can now be detected at runtime this still has to be done in a way that is
  preventing the driver from its regular operations which usually means a crash.

// Explain, in one sentence, how you tackled the research question.
In this thesis, we show that formally verifying the interaction of a driver with the @NIC is possible by implementing a model of the target hardware and using @BMC to prove that they cooperate correctly.

// How did you go about doing the research that follows from your big idea?
To show that the concept is viable in practice we implement a driver for the widely used Intel 82559ES @NIC.
This is done on the L4.Fiasco #cite(<l4doc>) microkernel so misbehavior of the driver can barely affect the system as a whole in the first place.

On top of that we are use the Rust programming language which guarantees additional safety properties out of the box.
The driver and model themselves use a custom Rust DSL in the spirit of svd2rust to make correct peripheral access easier.
Finally we show, using the Kani @BMC, that the driver correctly cooperates with a model of the 82559ES, where correctly means that:
- The driver doesn't panic
- The driver doesn't put the model into an undefined state
- The driver receives all packets that are received by the model
- The driver correctly instructs the model to send packets
#pagebreak()

= L4.Fiasco and L4Re
As a microkernel L4.Fiasco offers barely any functionality on a kernel level.
Instead the kernel hands out hardware resources to user space tasks which
in turn can distribute them further to other tasks. The idea being that we
can limit the amount of things that a task can interact with to the bare minimum
in order to reduce attack surface. The default set of user space programs that
ships with L4.Fiasco is the L4 runtime environment or L4Re for short.
In the following we illustrate the three main interaction mechanisms used by our driver.
== Capabilities
The most basic mechanism are so called capabilities. A capability is in a sense
comparable to a file descriptor. It describes an object that is somewhere in the
kernel and allows us to communicate with that object in a way. The difference to
a file descriptor is that any object that we get from the kernel is described by
a capability: threads, access to hardware, @IPC gates to other tasks etc.
#figure(
  image("figures/l4-caps-basic.svg", width: 80%),
  caption: [Capabilities],
) <l4caps>

This means that the set of capabilities that we initially grant our driver completely
determine the way it may interact with the rest of the operating system.
== Memory
// TODO: This is almost literally the docs
The separation of features out of the kernel in L4.Fiasco even goes as far as
removing memory management from the kernel. Instead a so called pager task is
designated as the memory manager of one or multiple threads. Once one of these
threads causes a page fault the kernel sends the pager an @IPC notification
and the pager returns either the backing page or an error. In the successful case
the kernel then proceeds to map that page into the address space of the faulting
thread. This allows the system to construct a hierarchy of memory mappings between tasks.
One task can grant a portion of its memory to another task which can in turn only
grant another sub-portion of that memory to another task etc.

While this can be used to implement normal functionality like an allocator it is
also an interesting feature for implementing programs that interact with hardware.
It is very common for a driver to share some of its own memory with the hardware
directly to allow high performance communication, this is called @DMA. However allowing
hardware arbitrary access to memory is a risk in two ways:
1. The hardware might overwrite or steal arbitrary memory contents
2. The driver that interacts with the hardware might do the same via instructing
   the hardware to, for example, write its data to an address the driver does not
   usually have access to.
For this reason a modern CPU usually ships a special @MMU that manages @DMA based memory access, the @IOMMU.
This means that by modeling the hardware as a special kind of task with memory mappings that
are managed by the @IOMMU instead of the regular @MMU we can allow our user space tasks
to still manage their @DMA mappings themselves.

== The Io server
The Io server is a task that owns all resources related to hardware that are not needed
by the kernel itself. This includes the PCI(e) bus, interrupts, IO memory and more.
Thus in order to access hardware a task needs to have an @IPC capability to talk with
the Io server. Instead of allowing processes with such a capability to obtain arbitrary
hardware resources each client is granted its own limited view of the hardware in the form
of a so called @VBus.
#figure(
  image("figures/io-overview.svg", width: 80%),
  caption: [Io architecture],
) <l4io>
As we can see in @l4io this allows us to limit the hardware that a task can see to the
bare minimum required for operation.
= Rust
We chose to use the Rust programming language for the entire implementation
due to three key factors:
1. It is memory safe by default while at the same time being competitive with
   the likes of C/C++ in terms of performance.
2. If necessary it still allows us to break out into a memory unsafe subset of
   language, unlike most memory safe languages such as Java.
3. It already has partial support on our target platform, L4.Fiasco.

In this section we aim to give an overview over the important Rust features
that we use. For a more complete overview of the Rust language
refer to #cite(<rustbook>).

== Ownership
All variables in Rust are immutable by default, hence the following program does
not compile:
#sourcecode[```rust
fn main() {
    let c = 0;
    println!("Hello: {}", c);
    c += 1;
    println!("Hello: {}", c);
}
```]
But mutability can be opted in to by using `let mut`. The idea behind immutable by
default is to limit the amount of moving pieces in a software to a minimum which
allows programmers to argue easier about their code. On top of that it plays an
important role in Rust's approach to memory safety.

The most notable feature of Rust that distinguishes it from other widely used programming
language right now is ownership and the part of the compiler that enforces it,
the borrow checker. It is the key feature in providing the memory safety per default.
As the name suggests, every value in Rust has an owner. The compiler enforces
that there can only be exactly one owner of a value at a time. Once this owner
goes out of scope the value gets freed, or in Rust terms, dropped.

On top of this a value can be moved from one owner to another. This happens in
two situations:
1. A value is returned from a function
2. A value is passed into another function
Once a value has been moved the previous owner is not capable of accessing it
anymore. For example the following program is not accepted by the compiler:
#sourcecode[```rust
fn func(s : String) {
    println!("Hello: {}", s);
}

fn main() {
    let s = String::from("World");
    // the value behind `s` gets moved here
    func(s);
    // `s` is no longer valid
    func(s);
}
```]
Rust offers two ways to resolve the above situation. The value can be cloned with
`s.clone()`, cheap values such as integers are automatically cloned. Alternatively
a reference to the value can be passed to the function, this is called borrowing.
On top of enforcing the ownership rule, the borrow checker also enforces that
references can never outlive the value they are referring to.

Keeping up the distinction between mutable and immutable values Rust supports two kinds of references:
1. Immutable ones: `&var : &Type`, they are a read only view of the data
2. Mutable ones: `&mut var: &mut Type`, they are a read and write view of the data
In order to prevent data races at compile time the borrow checker provides the
additional guarantees that a value can either:
- be immutably referenced one or more times
- or be mutably referenced a single time
Using this knowledge the above example can be rewritten to:
#sourcecode[```rust
fn func(s : &String) {
    println!("Hello: {}", s);
}

fn main() {
    let s = String::from("Hello World");
    func(&s);
    func(&s);
}
```]

While the borrow checker is capable of correctly identifying the vast majority
of code that does adhere to the above restrictions at compile time, it is not
infallible. Rust provides several ways to work around the borrow checker in case
of such false negatives.

The simplest ones are wrapper types that lift the ownership restrictions in one
way or another. We are interested in only one of those: `RefCell<T>`. This type
shifts the borrow checking to the run time, and throws errors if we violate the
restrictions while running.

If these wrapper types are still not enough to resolve the situation one can
fall back to using `unsafe` code. However writing buggy `unsafe` code will not
lead to compiler or run time errors but instead undefined behavior like in C/C++.
A common `unsafe` example is splitting a slice (a fat pointer) into two:
#sourcecode[```rust
unsafe fn split_at_unchecked<T>(data: &[T], mid: usize) -> (&[T], &[T]) {
    let len = data.len();
    let ptr = data.as_ptr();
    (from_raw_parts(ptr, mid), from_raw_parts(ptr.add(mid), len - mid))
}
```]
Note that we had to declare the function itself as `unsafe` as well since calling
`unsafe` functions is "viral" in Rust. That said we can provide safe API wrappers
around them that ensure preconditions for using the unsafe API are met. In this
example we have to ensure that `mid <= len` to prevent the second slice from
pointing into memory outside of the original one:
#sourcecode[```rust
fn split_at<T>(data: &[T], mid: usize) -> (&[T], &[T]) {
    assert!(mid <= data.len());
    unsafe { data.split_at_unchecked(mid) }
}
```]
Using the `unsafe` block feature like here is an instruction to the compiler to
trust the programmer that the contained code is safe in this context. The context
in the above function being that we already asserted the necessary preconditions.

Besides being used for memory management, the ownership system can also be used
for general resource management. For example a type `File` that wraps OS file
handles can automatically close itself while being dropped. This is achieved by
implementing the `Drop` trait:
#sourcecode[```rust
impl Drop for File {
    fn drop(&mut self) {
        close(self.handle);
    }
}
```]

== Traits
Traits in Rust fulfill a similar purpose to interfaces in languages like Java.
However they are strongly inspired by type classes from languages like Haskell
and thus provide a few extra features on top of the classical interface concept.

Declaring an interface style trait like `Drop` from above looks like this:
#sourcecode[```rust
trait Add {
    fn add(self, rhs: Self) -> Self;
}
```]
We might then continue to implement this trait for a bunch of basic types like
strings, integers etc. But implementing it for generic types such as pairs
gets more interesting. Intuitively we can add two pairs if the things in the
pairs can be added. We can express this constraint in a trait implementation:
#sourcecode[```rust
impl<L, R> Add for (L, R)
where
    L: Add,
    R: Add,
{
    fn add(self, rhs: Self) -> Self {
        (self.0.add(rhs.0), self.1.add(rhs.1))
    }
}
```]
If we try to call `add` on a pair value Rust will start looking for fitting instances
for the types of the values contained in the pairs. In particular it will recursively
chain this instance to figure out how to add values of types like `(u8, (u8, u8))`.

Furthermore traits can have generic arguments themselves as well. For example
a heterogeneous `Add` trait which supports both normal addition of integers etc.
but also things like adding a `Duration` on top of a `Time` might look like this:
#sourcecode[```rust
trait Add<Rhs, Out> {
    fn add(self, rhs: Rhs) -> Out;
}

// Add raw times
impl Add<Time, Time> for Time {
    fn add(self, rhs: Time) -> Time { /* */ }
}

// Add relative durations onto some time
impl Add<Duration, Time> for Time {
    fn add(self, rhs: Duration) -> Time { /* */ }
}
```]

There is one drawback to this approach: In order to find an `Add` instance
all of the types involved have to be known. Otherwise the trait system cannot
know whether to use the first or the second instance. While it is very likely that
the compiler already knows the input types it is much less likely that it will be
able to figure out the output type on its own. This would force users to put explicit
type annotations in order to make the instance search succeed. In order to make
using this trait easier we can use so called associated types:

#sourcecode[```rust
trait Add<Rhs> {
    type Out;
    fn add(self, rhs: Rhs) -> Self::Out;
}

// Add raw times
impl Add<Time> for Time {
    type Out = Time;
    fn add(self, rhs: Time) -> Time { /* */ }
}

// Add relative durations onto some time
impl Add<Duration> for Time {
    type Out = Time;
    fn add(self, rhs: Duration) -> Time { /* */ }
}
```]

Rust enforces that there can only be one instance for one assignment of generic
variables. This means that while we could have previously written instances like
`Add<Duration, Time> for Time` and `Add<Duration, Duration> for Time` the new design
doesn't allow this as we would have two instance of the form `Add<Duration> for Time`.
While associated types take a bit of flexibility away from the programmer they do
allow Rust to start instance search without being known from type inference.
Whether to use generic or associated types thus comes down to a usability
(through type inference) vs flexibility (through additional permitted instances) trade off.

== Macros
While the recursive chaining of trait instances already allows a great deal of
compile time code generation there are many situations where traits are not sufficient.
A common case is to automatically generate the same code for a list of identifiers to e.g.
test them or add similarly shaped trait instances to all of them.
This is where Rust's macro system comes into play. Unlike the substitution based macros in C/C++,
Rust's macro system allows users to write proper syntax tree to syntax tree transformations.
Generally speaking Rust supports two kinds of macros:
1. declarative macros, they use an @EBNF inspired DSL to specify the transformation
2. procedural macros, they use arbitrary Rust code for the transformation
The macros used in this work are exclusively declarative ones so we only describe this approach.
To illustrate the capabilities of declarative macros we embed a small math DSL into Rust:
#sourcecode[
```
x = 1;
y = 2 * x;
y;
x;
```]
Where if a variable is alone on a line we print its value. This can be done using
a declarative macro in the style of a so called @TT muncher:
#sourcecode[```rust
macro_rules! math {
    ($var:ident = $e:expr; $($tail:tt)*) => {
        let $var = $e;
        math!($($tail)*);
    };
    ($var:ident; $($tail:tt)*) => {
        let x = format!("Value: {}", $var);
        println!("{}", x);
        math!($($tail)*);
    };
    () => {};
}
```]
As we can see this macro has 3 "production rules":
1. If we see `x = e; ...` we bind `x` to the value of `e` and recursively process
   the remaining token trees in the input.
2. If we see `x; ...` we print the value of `x` and process the rest.
3. If there is no argument we do nothing. This is to handle the case when the
   remaining token tree list is empty.

The above macro also demonstrates an important guarantee of Rust macros, macro hygiene.
We call a macro system hygienic when identifiers that are used within the body of a macro
(like `let x = format...`) cannot collide with user provided identifiers (like the `x` from the input).
So instead of `x` suddenly turning out to be a string once we want to print it, Rust
kept the values separate and the following main function produces the expected output:
#sourcecode[```rust
fn main() {
    math! {
        x = 1;
        y = 2 * x;
        y;
        x;
    }
}
```]

```
Value: 2
Value: 1
```
The precise workings of the declarative macro syntax and all the kinds
of syntax that can be matched upon are far out of scope for this work so we refer to
#cite(<rustmacrobook>) for a more detailed introduction.
= Formal Verification in Rust
To our knowledge there do currently exist three actively maintained and reasonably
popular tool for (semi)-automated verification of Rust code:
- Kani #cite(<kani>)
- Creusot #cite(<creusot>)
- Prusti #cite(<prusti>)
A key feature for our verification effort is the ability to verify `unsafe` code
reasonably easy. According to its issue tracker, Creusot is currently not capable
of verifying `unsafe` code at all #footnote[https://github.com/xldenis/creusot/issues/36].
This already rules it out completely for us. With Prusti the tool is not incapable
of processing `unsafe` code but its automation capabilities are very limited.
For example the following example cannot be verified by Prusti automatically:
#sourcecode[```rust
fn test() {
    let mut test : Vec<u8> = Vec::new();
    test.push(0);
    unsafe {
        test.as_mut_ptr().write(10);
        if test.as_ptr().read() != 10 {
            // This panic cannot be hit
            panic!("Ahhh");
        }
    }
}
```]
Kani on the other hand is fully able to verify these and much more complicated examples,
which made us pick it for this verification effort.

Kani is implemented as a code generation backend fo the Rust compiler. However
instead of generating executable code, it generates an intermediate representation
of @CBMC #cite(<cbmc>). While @CBMC is originally intended for verifying C code,
by using this trick Kani is able to make use of all the features that already
exist in @CBMC. By default Kani checks the following properties of a given piece
of Rust code:
- memory safety, that is:
  - pointer type safety
  - absence of invalid pointer indexing
  - absence of out of bounds accesses
- absence of mathematical errors like arithmetic overflow
- absence of runtime panics
- absence of violations of user-added assertions

For example the following Rust code would crash if `a` has length $0$ or if `i`
is sufficiently large:
#sourcecode[```rust
fn get_wrapped(a: &[u32], i: usize) -> u32 {
    return a[i % a.len() + 1];
}
```]
We can check this using Kani as follows:
#sourcecode[```rust
#[cfg(kani)]
#[kani::proof]
fn check_get_wrapped() {
    let size: usize = kani::any();
    let index: usize = kani::any();
    let array: Vec<u32> = vec![0; size];
    get_wrapped(&array, index);
}
```]
Kani ends up spotting both failures and an additional one:
```
SUMMARY:
Failed Checks: This is a placeholder message; Kani doesn't support message formatted at runtime
 File: ".../alloc/src/raw_vec.rs", line 534, in alloc::raw_vec::capacity_overflow
Failed Checks: attempt to calculate the remainder with a divisor of zero
Failed Checks: index out of bounds: the length is less than or equal to the given index
```
As we just saw we can use the `kani::any()` function to generate arbitrary symbolic
values of basic types like integers. These basic values can then be used to build
up more complex symbolic values like the `Vec<u32>` from above. However there is
one more issue than expected with the proof, the harness caused an error
in the allocator for `Vec` because it is possible to request too much memory. Since the error is
introduced by the proof code itself, instead of the code under test, we probably
want to get rid off it. This can be achieved by putting a constraint on `size`
using the `kani::assume()` function:
#sourcecode[```rust
#[cfg(kani)]
#[kani::proof]
fn check_get_wrapped() {
    let size: usize = kani::any();
    kani::assume(size < 128);
    let index: usize = kani::any();
    let array: Vec<u32> = vec![0; size];
    get_wrapped(&array, index);
}
```]

In the two harnesses above there is no iteration, this makes it easy for Kani to
explore the entire state space. Once we introduce loops Kani unfolds them
in order to explore the state space. In many situations we need to limit this
unfolding to hold it back from exploring a large or potentially infinite state space:
#sourcecode[```rust
fn zeroize(buffer: &mut [u8]) {
    for i in 0..buffer.len() {
        buffer[i] = 0;
    }
}

#[cfg(kani)]
#[kani::proof]
#[kani::unwind(1)] // deliberately too low
fn check_zeroize() {
    let size: usize = kani::any();
    kani::assume(size < 128);
    kani::assume(size > 0);
    let mut buffer: Vec<u8> = vec![10; size];

    zeroize(&mut buffer);
}
```]
Instead of simply verifying only one loop iteration Kani tells us that this
bound is too low:
```
Failed Checks: unwinding assertion loop 0
```
Once we increase it to $128$ all checks pass.

The last feature that is of interest for this work are stubs. They allow us to
replace functions in the code under verification with mocks. This is useful
for verifying functions that are out of reach for Kani, for example interactions
with the operating system:
#sourcecode[```rust
use std::{thread, time::Duration};

fn interaction() {
    thread::sleep(Duration::from_secs(1));
    rate_limited_functionality();
}

#[cfg(kani)]
#[kani::proof]
fn check_interaction() {
    interaction();
}
```]
This code is rejected by Kani with:
```
Failed Checks: call to foreign "C" function `nanosleep` is not currently supported by Kani.
```
If we are only interested in verifying things about `rate_limited_functionality`
we can tell Kani to replace `thread::sleep` with an empty function:
#sourcecode[```rust
fn mock_sleep(_dur : Duration) {}

#[cfg(kani)]
#[kani::proof]
#[kani::stub(std::thread::sleep, mock_sleep)]
fn check_interaction() {
    interaction();
}
```]
= Intel 82599
The communication with the Intel 82599 network card happens in roughly three phases:
1. PCI device discovery and setup
2. Configuration of the actual device
3. Sending and receiving packets
In the following chapter we aim to give an overview over these three sections with
a particular focus on the third one as this is our main verification concern.
== PCI setup
A normal driver would initially have to look for the device on its own. However as we are
on L4, the Io server instead searches for these devices and presents them
to us through a @VBus. Once we have obtained this handle to our device we can start
talking to it through the PCI config space.

This config space is in essence a memory like structure that we can read from and write to using
@IPC calls to the Io server. The beginning (and relevant to us part) of this structure
can be seen in @pcicfg. The fields that are of most interest to our driver are
the 6 @BAR ones, they contain addresses of memory regions that are shared between
our CPU and the device which we can use for @MMIO based configuration.

The datasheet
of the device @intel:82599 tells us that the relevant @BAR for configuring the device
is the first one. Thus the first thing the driver has to do is ask the Io server
to map the memory that @BAR 0 points to into our address space so we can actually
begin device initialization.

#figure(
  bfield(
    bytes(2)[Device ID], bytes(2)[Vendor ID],
    bytes(2)[Status Register], bytes(2)[Control Register],
    bytes(3)[Class Code], bytes(1)[Revision ID],
    bytes(1)[Reserved], bytes(1)[Header Type], bytes(1)[Latency Timer], bytes(1)[Cache Line Size],
    bytes(4)[@BAR 0],
    bytes(4)[@BAR 1],
    bytes(4)[@BAR 2],
    bytes(4)[@BAR 3],
    bytes(4)[@BAR 4],
    bytes(4)[@BAR 5],
  ),
  caption: [Beginning of the PCI config space]
) <pcicfg>

== Device Configuration <devicecfg>
After this mapping is done the driver has to follow the initialization procedure
described in section 4.6.3 of @intel:82599. Almost all of this configuration can
be done exclusively through the @MMIO based interface that was established previously.

The exception to this is the setup of @DMA based queues which are used to
transmit and receive packets. The packets do not get sent directly through these
queues though, instead so called descriptors are written to the queue. They contain
the address of the actual packet data in the TX case and the address to write
packet data to in the RX case. This means that the driver has to set up 3 @DMA
mapped buffers in total:
- one for the RX queue
- one for the TX queue
- one as a memory pool for packet buffers
After this setup is done the actual communication with the network can begin.
The details of this queue based communication as well as its verification are
discussed in @verix and @mix as they are the main investigation point of this work.

= Verifying the driver
In this chapter we lay out the rough architecture that allows us to run the driver
both on L4 and on a model of the hardware for verification purposes. Afterwards
we formalize the notion of what it means for our driver to be correct and lay
out how we verified these properties using Kani.

== Architecture
#figure(
  image("figures/drawio/verix-arch.drawio.pdf.svg", width: 80%),
  caption: [Architecture]
) <arch>
The rough architecture for the project is laid out in @arch. The end product is
an application called `verix-fwd` which mirrors received packets back to the sender.
`verix-fwd` is mainly powered by `verix-lib` which is the actual driver and the subject
of our verification efforts. `verix-lib` in turn does not directly talk to the hardware
but rather through an abstract interface called `pc-hal` which has two implementations:
1. `pc-hal-l4` this is the one we actually used in production on the hardware. It implements
   the abstract interface provided by `pc-hal` by calling into responsible the L4 APIs.
   It is discussed in @pc-hal
2. `mix`, the "model ix". It provides a software model of the @NIC that implements the `pc-hal`
    abstract interface. When plugged into `verix-lib` instead of `pc-hal-l4` we can use Kani
    to verify properties about the interaction of the driver with the modeled @NIC.
    It is discussed in @mix.
== pc-hal <pc-hal>
The main job of `pc-hal` is to provide a trait based abstraction over the L4 hardware related
APIs in order to allow us to plug `mix` in. The design is spirit of the
Rust Embedded @WG's `embedded-hal` (TODO: cite). In particular we provide abstractions for:
- @DMA mappings
- @VBus interface
- PCI config space
- raw pointer based @MMIO interfaces
Demonstrating how all of these interfaces work would be out of scope for this work
so we instead only give an exemplary view of the PCI config space abstraction.
It is implemented as a single trait, `FaillibleMemoryInterface32`:
#sourcecode[```rust
pub trait FailibleMemoryInterface32 {
    type Error;
    type Addr;

    fn write8(&mut self, offset: Self::Addr, val: u8) -> Result<(), Self::Error>;
    fn write16(&mut self, offset: Self::Addr, val: u16) -> Result<(), Self::Error>;
    fn write32(&mut self, offset: Self::Addr, val: u32) -> Result<(), Self::Error>;
    fn read8(&self, offset: Self::Addr) -> Result<u8, Self::Error>;
    fn read16(&self, offset: Self::Addr) -> Result<u16, Self::Error>;
    fn read32(&self, offset: Self::Addr) -> Result<u32, Self::Error>;
}
```]
The interface has to be designed in a faillible way because as discussed previously
the communication with the PCI config space happens through @IPC, which can return errors.
In addition to that we also abstract over the address data type in order to possibly
allow more diverse usage of this trait in other applications if they ever arise.
The reason that both of the type parameters are implemented as associated types instead
of generic ones, is that the specific types are then known at the instances of the trait
already. This allows us to construct specific error values and do proper computation
with the offset in the instance, instead of having to abstract further over error kinds
and address manipulation.

While the majority of the interfaces provided by `pc-hal` could probably be made sufficiently
general to fit multiple platforms, they are currently very much designed with the L4 interface
in mind. This makes the `pc-hal-l4` implementation of the traits mostly a thin wrapper around 
the Rust L4 APIs. These APIs were initially developed in #cite(<humendal4>) and extended by
us in order to support more hardware related things in addition.

In addition to the traits `pc-hal` also provides a few utility functions that work
on top of them. The most notable one here is a type safe @MMIO abstraction in the spirit
of the Rust Embedded @WG's `svd2rust` tool (TODO: cite). `svd2rust` allows Rust Embedded developers
to automatically generate type safe implements for @MMIO interfaces of ARM and RISC-V chips.
The need for such a type safe API arose because interacting with an @MMIO interface in Rust
directly uses direct pointer manipulation together with lots of constants and bit operations:
#sourcecode[```rust
pub const IXGBE_CTRL: u32 = 0x00000;
pub const IXGBE_CTRL_LNK_RST: u32 = 0x00000008;
pub const IXGBE_CTRL_RST: u32 = 0x04000000;
pub const IXGBE_CTRL_RST_MASK: u32 = IXGBE_CTRL_LNK_RST | IXGBE_CTRL_RST;

fn set_reg32(&self, reg: u32, value: u32) {
    unsafe {
        ptr::write_volatile(
            (self.addr as usize + reg as usize) as *mut u32,
            value
        );
    }
}

self.set_reg32(IXGBE_CTRL, IXGBE_CTRL_RST_MASK);
```]


`svd2rust` provides this API by automatically generating code from an XML based interface description, 
the SVD files. While such files are not available for the Intel 82559 we end up generating an
API that works very similarly to the `svd2rust` ones. However our implementation is not file to file converter
but instead implemented as a declarative Rust macro. The user interface of our macro looks as follows:

#sourcecode[```rust
mm2types! {
    Intel82559ES Bit32 {
        Bar0 {
            ctrl @ 0x000000 RW {
                reserved0 @ 1:0,
                pcie_master_disable @ 2,
                lrst @ 3,
                reserved1 @ 25:4,
                rst @ 26,
                reserved2 @ 31:27
            }
        }
    }
}
```]
We declare a device called `Intel82559ES` which has @MMIO registers of size 32 bit.
This device has an @MMIO interface called `Bar0` which contains a register `ctrl` at offset `0x0`
which is readable and writable and has a number of fields at certain bit ranges.
The equivalent of the above register access looks as follows in our API:
#sourcecode[```rust
bar0.ctrl().modify(|_, w| w.lrst(1).rst(1));
```]
While this involves a closure and several function calls, all of the operations here end up
getting inlined and optimized by the compiler. This optimization is so good, that our code
ends up producing the same assembly code as the pointer based interface above. Describing
how the entire `svd2rust` style API works is out of scope here but conceputally
described at (TODO: link to docs)

In addition to this, the macro also supports 64 bit based @MMIO which we use to generate
type safe interfaces for the packet descriptors. The way this is usually done looks
as follows:
#sourcecode[```rust
#[repr(C)]
pub struct ixgbe_adv_rx_desc_read {
    pub pkt_addr: u64,
    pub hdr_addr: u64,
}

ptr::write_volatile(
    &mut (*desc).pkt_addr as *mut u64,
    phys_addr as u64,
);
```]
Which, while already typed to a degree, still allows for quite a bit of error compared
to the intrinsically typed version that our macro provides.

== verix <verix>
As mentioned above verix is the code that actually interacts with the hardware and thus
the code that we are actually interested in verifying. The driver itself is largely
based on the ixy driver, originally from #cite(<emmerichixy>) and later ported to Rust in
#cite(<ellmannixy>). The three main differences between our port and the Rust original
are:
1. the abstract interface instead of the Linux userspace APIs 
2. a reduction of unsafe code from the driver itself, by generating the safe @MMIO APIs
3. we only ended up porting the polling variant of the driver, this means that our setup
   uses no interrupts.

Since the initial device setup is very linear, we won't go into the details of how the driver performs these steps.
The packet receive and transmit procedure one the other hand are more involved. 
We begin by explaining the receive procedure as it is slightly simpler than the transmit one.

=== Receiving packets
As mentioned in <devicecfg> packet receiving is done through a @DMA mapped queue.
This queue is implemented as a ring buffer in memory whose state is determined by 4
@MMIO mapped registers:
1. RDBAL and RDBAH, they contain the low and high half of the base address
2. RDLEN, the length of the buffer behind the base address in bytes
3. RDH and RDT which are the head and tail of the queue that is simulated on
   top of this ring buffer
An example state of an RX queue, configured with 8 slots, might thus look like this:
#figure(
  image("figures/drawio/rx-queue.drawio.pdf.svg", width: 70%),
  caption: [Example RX queue]
) <rx-queue-1>

According to Section 7.1 of #cite(<intel:82599>) this state is to be interpret as follows:
1. The slots $1, 2, 3, 4$ (the interval $["RDH", "RDT")$) are owned by the hardware and contain so called read descriptors.
2. The slots $5 , 6, 7, 0$ (the interval $["RDT", "RDH")$) are owned by the software and are either being currently
   processed or there is currently no packet buffer free to turn them back into read descriptors.
Both of these descriptor types are $2 dot.c 64$ bit value long structures.
Read descriptors, as can be seen in @adv_rx_read, are very basic. They consist of three parts:
1. The Packet Buffer Address, this is a pointer to the @DMA mapped slice of memory that we expect
   the hardware to write a packet to.
2. The Header Buffer Address, this can be used for additional hardware features that are not in use by us.
3. The DD bit. This stands for Descriptor Done and is present in both the read and the write back descriptor.
   It is set by the hardware to indicate that this descriptor has been processed.

Once the hardware receives a packet, it places its data at the Packet Buffer Address of the first free
read descriptor and sets the DD bit. After that is done a write back descriptor as described in
@adv_rx_wb is put into the consumed slot. This descriptor kind contains a lot of meta information,
most of which concerns more advanced features. The fields that are relevant in the basic
configuration setup of verix are:
1. The packet length which contains how many bytes of the buffer in the read descriptor were actually used for a received packet
2. The extended status register which contains two fields that are relevant to us:
   1. The EOP bit, if it is set this indicates an end of a packet. This is relevant because the @NIC can in theory
      be configured to split up packets across multiple descriptors. As we don't use this feature we expect EOP to
      always be set
   2. The DD bit at the same position as the DD bit in the read descriptor and serves the same purpose

After this procedure is done the hardware advances RDH, possibly overflowing back to the start
of the ring buffer while doing so.

#figure(
  bfield(bits: 64,
    bits(64)[Packet Buffer Address],
    bits(63)[Header Buffer Address], bit[#flagtext("DD")],
  ),
  caption: [Advanced Receive Descriptors - Read]
) <adv_rx_read>

#figure(
  bfield(bits: 64,
    bits(32)[RSS Hash], bit[#flagtext("SPH")], bits(10)[HDR_LEN], bits(4)[RSCCNT], bits(13)[Packet Type], bits(4)[RSST],
    bits(16)[VLAN Tag], bits(16)[PKT_LEN], bits(12)[Extended Error], bits(20)[Extended Status]
  ),
  caption: [Advanced Receive Descriptors - Write-Back]
) <adv_rx_wb>

The way this exchange of buffers is implemented in verix is as follows. The driver maintains three additional things for
itself:
1. A mini allocator that manages the buffers in the @DMA mapped packet buffer array. It can request memory in buffers of 2048
   byte, which should be sufficient for all packets as they cannot exceed the @MTU of 1500 byte.
2. An array with the same amount of slots as the ring buffer. Here it saves which buffer is used for which slot in the
   ring buffer as this information is not maintained by the write back descriptor.
3. The `rx_index`, it contains the location that the driver will read the next packet from. This allows it to simply poll the
   DD bit of the descriptor at `rx_index` in order to figure out whether a packet was received.

In addition to this the driver maintains two important invariants:
1. `rx_index` is always $"RDT" + 1$.
2. It strengthens the assumption of the hardware that all descriptors in the interval $["RDH", "RDT")$ contain
   read descriptors to the interval $["RDH", "RDT"]$

These two assumptions allow for the receive operation of one packet to be implemented as follows:
1. Poll until DD at `rx_index` is set to 1.
2. Remember the buffer that was used at `rx_index` to return it later.
3. Replace the buffer remembered for `rx_index` with a fresh one and write its meta information as a read descriptor
   with DD set to 0.
4. As the descriptor at RDT is already initialized as a read one simply advance RDT and the `rx_index`.

On top of this the driver implements a batching mechanism which repeats the procedure up to a certain batch size in
order to increase performance.

=== Transmitting packets
The structure of the TX queue is the same as the RX one, except that the registers are called TDBAL, TDBAH, TDLEN, TDH
and TDT. However the structure of the descriptors themselves is drastically different. The read ones contain a large
amount of meta information this time as can be seen in @adv_tx_read, the relevant pieces for our basic configuration
are:
1. The Packet Buffer Address, it points to the data that we wish to send
2. They PAYLEN, it contains how large the packet is as a whole. As we again only use single descriptor packets this
   has the same value as DTALEN
3. The DTYP contains what kind of descriptor we are using since the hardware also supports a legacy format. This is always
   set to the advanced format in our driver.
4. The DCMD is a bit vector for a series of options, the relevant ones for our configuration are:
   1. DEXT which indicates that we use advanced descriptors as well
   2. RS which makes the hardware report the status of the descriptor by setting the DD bit
   3. IFCS which makes the hardware compute the Ethernet CRC frame checksum for us 
   4. EOP which has the same semantics as in receive descriptors
5. The STA which as a single relevant field, the DD bit with the same semantics as in receive descriptors

The procedure to send a packet is very similar to the receive one, we insert a read descriptor at the beginning of the
section that is owned by the software and advance the RDT. Eventually the hardware picks up on the new descriptor,
processes it and writes a write back descriptor with DD set. The transmit write back descriptors have a much simpler structure,
as can be seen in @adv_tx_wb, it only contains a STA field with the same structure as STA in the read descriptors.

#figure(
  bfield(bits: 64,
    bits(64)[Packet Buffer Address],
    bits(18)[PAYLEN], bits(6)[POPTS], bit[#flagtext("CC")], bits(3)[IDX], bits(4)[STA], bits(8)[DCMD], bits(4)[DTYP], bits(2)[#flagtext("MAC")], bits(2)[#flagtext("RSV")], bits(16)[DTALEN]
  ),
  caption: [Advanced Transmit Descriptors - Read]
) <adv_tx_read>

#figure(
  bfield(bits: 64,
    bits(64)[RSV],
    bits(28)[RSV], bits(4)[STA] ,bits(32)[RSV]
  ),
  caption: [Advanced Transmit Descriptors - Write-Back]
) <adv_tx_wb>


There is one considerable difference compared to the receive procedure, the buffers have to be freed after the
hardware marked them as processed. For this reason the transmit function maintains 4 additional values:
1. The mini allocator that is shared with the receive part
2. An array with buffers similar to the one in the receive part
3. The `tx_index` which points to the next location we write a packet to.
4. The `clean_index` which marks the location of the next descriptor that we need to free

The driver only maintains one invariant on this state, `tx_index` is always equal to TDT.
The algorithm for transmitting a packet is unsurprisingly also very similar to the receive one:
1. Try to free as many packets as possible by freeing all buffers from `clean_index` to the first one that doesn't have DD set.
2. Insert the read descriptor at `tx_index`.
3. Replace the buffer that we remember for `tx_index` with the one that was just placed
4. Advance TDT and `tx_index`.

Just like the receive algorithm the transmit one also implements a batching procedure on top of this by repeating steps
2-4 up to a certain batch size.

== mix <mix>
`mix` is our main tool in verifying the above procedures. Like the driver `mix` is logically
split into three parts as well:
1. A model for the PCI @VBus to verify discovery.
2. A model that covers the @MMIO based initialization.
3. A model for the interactions that are supposed to happen while receiving and transmitting packets.

All three of these models hook into verix by implementing the traits provided by `pc-hal` and then plugging
into the APIs that are usually filled with `pc-hal-l4`.

The model for the PCI @VBus is rather straight forward as, just like the L4 one, it merely simulates
a bus with a single relevant PCI device, the Intel 82599. The Kani harness that we use to verify
this procedure simply feeds this simulated @VBus to the discovery procedure of verix and ends asserts
that the proper device is found.

The modeling of the initialization procedure is more complicated. An uninitialized Intel 82599 in
`mix` contains a state machine with 18 states. All of the @MMIO register writes are hooked up to
this state machine through the `pc-hal` interfaces. As the writes occur we assert that the registers
mentioned in the current step of the initialization get the correct values and the previous
registers are not further modified (unless required by the procedure). After the procedure is
done we assert that we are in the final state to verify that the device has in fact been initialized.

While both of these test targets contain very linear code and the Kani harnesses don't really make
use of symbolic variables we still run them through Kani instead of a normal mock test. This is because
we also want the additional guarantees that Kani gives us, in particular the pointer related ones.

The most complex model is the one for receiving and transmitting packets. Just like in @verix we begin
with discussing the receive half as the transmit one works quite analogously. The properties that we aim
to verify for the receive procedure are:
1. If there is at least one packet present on the queue and we have memory to replace the slot we receive it
2. If there is no packet present on the queue we don't receive anything
3. The additional properties that Kani gives us for free, again the ones of particular interest are
  pointer and memory related ones.

=== Verifying receive
We begin by defining what it means for a queue state to be valid and then establish
an induction based proof to demonstrate that the queue state always remains valid. Afterwards
we establish that the properties 1 and 2 always hold in a valid queue state.

#definition("Valid receive read descriptor")[
    We call a receive read descriptor valid iff:
    - DD is 0
    - The Header Buffer Address is 0
    - The Packet Buffer Address points to valid memory for at least 1500 bytes
]  <valid_adv_rx_read>

#definition("Valid receive write back descriptor")[
    We call a receive write back descriptor valid iff:
    - DD is 1
    - EOP is 1
] <valid_adv_rx_wb>

Next we split up the queue into two different sections based on RDH, RDT and `rx_index`.
While our queue is implemented as a ring buffer we will not concern ourselves with the details
of the ring buffer semantics in these definitions for sake of clarity. These details are however
taken care of in the Kani implementations of these definitions.

#definition("Receive read section")[
    The receive read section of a queue $Q$ covers the interval $Q["RDH", "RDT"]$.
]

#definition("Valid receive read section")[
    We call a receive read section valid, iff all the descriptors in its range are
    valid receive read descriptors according to @valid_adv_rx_read.
]

#definition("Receive write back section")[
    The receive write back section of a queue $Q$ covers the interval $Q["rx_index", "RDH")$.
]

#definition("Valid receive write back section")[
    We call a receive write back section valid, iff all the descriptors in its range are
    valid receive write back descriptors according to @valid_adv_rx_wb.
]

In addition to this we aim to maintain the invariant on `rx_index` that was previously mentioned in
@verix.

#definition("rx_index invariant")[
    The `rx_index` is always $"RDT" + 1$.
]

#definition("Valid receive queue")[
    We call a receive queue valid iff:
    - Its receive read section is valid
    - Its receive write back section is valid
    - Its `rx_index` invariant is maintained
]

We now establish the theorem that we always remain in a valid receive queue state as well as the
properties that we are actually interested in, based on this result.

#theorem("The initialized receive queue state is valid")[
    After the initialization procedure the receive queue is in a valid state.
] <init_rx_valid>

#proof[
    This is verified by a Kani test harness.
]

#theorem("The receive queue state remains valid")[
    Assuming that we already are in a valid queue state we always remain in a valid queue state
    after calling the receive procedure.
] <step_rx_valid>

#proof[
    This is verified by a Kani test harness.
]

#theorem("The driver always remains in a valid receive queue state")[
    Assuming that we try to receive packets after initialization, the receive queue
    always remains in a valid state.
] <rx_valid>

#proof[
    This statement cannot directly be expressed in Kani. However it clearly follows from
    the @init_rx_valid and @step_rx_valid as those are the base case and inductive case for an induction
    proof on this statement.
]

#theorem("The driver receives a packet if it is present")[
    In any receive queue state that is reachable from the initial state, assuming that:
    - We have at least one free packet buffer 
    - There is at least one packet on the queue (i.e. the write back section is non empty)
    The driver receives this packet.
]

#proof[
    This is verified by a Kani test harness which assumes that we are in a valid receive queue state.
    This assumption is valid according to @rx_valid.
]

#theorem("The driver receives no packets if the queue is empty")[
    In any receive queue state that is reachable from the initial state, assuming that
    there are no packets on the queue (i.e. the write back section is empty),
    the driver will not receive any packets.
]

#proof[
    This is verified by a Kani test harness which assumes that we are in a valid queue state.
    This assumption is valid according to @rx_valid.
]

=== Verifying transmit
While the transmit procedure does introduce additional complexity through the cleanup procedure,
verifying this procedure was not possible with Kani as we will discuss in @limitations.
Thus we limit ourselves to specifying and verifying the correctness of the transmit procedure
without cleanup. The proof ends up working very similarly to the receive one:

#definition("Valid transmit read descriptor")[
    We call a transmit read descriptor valid iff:
    - all of the features in the descriptor that are unused are disabled
    - DTYP is set to the advanced pattern
    - RS is 1
    - DD is 0
    - IFCS is 1
    - EOP is 1
    - The PAYLEN is greater than zero
    - The Packet Buffer Address points to valid memory for at least 1500 bytes
]  <valid_adv_tx_read>

#definition("Valid transmit write back descriptor")[
    We call a transmit write back descriptor valid iff DD is 1.
] <valid_adv_tx_wb>

Next we split up the queue into two different sections based on TDH, TDT and `tx_index`.
While this is very similar to the RX setup there is a slight difference.

#definition("Transmit read section")[
    The transmit read section of a queue $Q$ covers the interval $Q["TDH", "TDT")$.
]

#definition("Valid transmit read section")[
    We call a transmit read section valid, iff all the descriptors in its range are
    valid transmit read descriptors according to @valid_adv_tx_read.
]

#definition("Transmit write back section")[
    The transmit write back section of a queue $Q$ covers the interval $Q["clean_index", "TDH")$.
]

#definition("Valid transmit write back section")[
    We call a transmit write back section valid, iff all the descriptors in its range are
    valid receive write back descriptors according to @valid_adv_tx_wb.
]

In addition to this we aim to maintain two invariants on `tx_index` and `clean_index`:

#definition("tx_index invariant")[
    The `tx_index` is always equal to TDT.
]

#definition("clean_index invariant")[
    The `clean_index` is always after the `tx_index` and before TDH.
]

#definition("Valid transmit queue")[
    We call a transmit queue valid iff:
    - Its transmit read section is valid
    - Its transmit write back section is valid
    - Its `tx_index` invariant is maintained
    - Its `clean_index` invariant is maintained
]

The proof that we always remain in a valid transmit queue state is exactly the same as
@rx_valid, except that we use transmit instead of receive definitions, so we omit it here.

#theorem("The driver always remains in a valid transmit queue state")[
    Assuming that we try to transmit packets after initialization, the transmit queue
    always remains in a valid state.
] <tx_valid>

#proof[
    This statement is proven analogously to @rx_valid. This includes the limitation that the
    induction itself is not verified by Kani, only the base case and the step.
]

#theorem("The driver transmits a packet if the queue is not full")[
    In any transmit queue state that is reachable from the initial state, assuming that
    the queue is not full (i.e. the write back section doesn't contain the entire queue),
    the driver will transmit a packet successfully.
]

#theorem("The driver doesn't transmit packets if the queue is full")[
    In any transmit queue state that is reachable from the initial state, assuming that
    the queue is full (i.e. the write back section does contain the entire queue),
    the driver will not transmit a packet.
]

#proof[
    This is verified by a Kani test harness which assumes that we are in a valid transmit queue state.
    This assumption is valid according to @tx_valid.
]

=== Limitations <limitations>
In verifying the above theorems we met two main limitations of Kani in our use case.
The first one was that Kani was seemingly unable to translate the dropping of our packet
data structure into the @CBMC input format. Unlike normal data structures we implemented
a custom `Drop` functionality that returns the packet buffer back to the mini allocator
while dropping:
#sourcecode[```rust
pub struct Packet<'a, E, Dma, MM>
where
    MM: pc_hal::traits::MappableMemory<Error = E, DmaSpace = Dma>,
    Dma: pc_hal::traits::DmaSpace,
{
    addr_virt: *mut u8,
    addr_phys: usize,
    len: usize,
    pool: &'a Mempool<E, Dma, MM>,
    pool_entry: usize,
}

impl<'a, E, Dma, MM> Drop for Packet<'a, E, Dma, MM>
where
    MM: pc_hal::traits::MappableMemory<Error = E, DmaSpace = Dma>,
    Dma: pc_hal::traits::DmaSpace,
{
    fn drop(&mut self) {
        self.pool.free_buf(self.pool_entry);
    }
}
```]
While Kani was not inherently unable to deal with custom `Drop` implementations it was
unable to translate `self.pool.free_buf` itself in a reasonable amount of time.

This is the reason that we did not end up verifying the clean up of the transmit queue above.
Additionally we also had to leak all of the packets in the packet receive and transmit
lemmas to avoid the same bug. While this does open the possibility of a bug in the allocator
we believe the main idea of our theorems, namely that we maintain a valid queue state all of the time,
to still be valid.

The second limitation is in the size of our problem. The above approach already reduces
the verification problems to just one receive or transmit action on some queue. While
this considerably reduces the search space we were still not able to use queues that are of
the same size as the "real world" queues in our verification. In production our driver
uses queues with 512 slots and batch sizes up to 64. We only managed to go up to 16 slots
and a batch size of 1 before going out of memory in the Kani harnesses. This is a large limitation
of the guarantees that we are able to provide with respect to the real world use case.
That said, Kani is planning on improving its verification capabilities for large heap structures
and will hopefully support our real world problem sizes in the future.

#pagebreak()

= Conclusion
== Results
Based on the git history of `mix` we estimate that the entire verification effort consumed about 120
man hours. This excludes the porting effort of the driver onto L4 which did consume more time due to
our inexperience with the L4 hardware framework in the beginning. As detailed in the previous chapter
we did manage to verify the guarantees that we set out to show in the beginning, as well as the free
guarantees that Kani provides, up to the rather small queue size of 16.

In order to break this boundary we did attempt to use 4 SAT solvers for our harness:
- Minisat TODO cite
- Cadical #cite(<cadical-kissat>), the Kani default
- Kissat #cite(<cadical-kissat>)
- Glucose #cite(<glucose>)

These experiments were run on a virtualized cloud VM with 48GB of RAM and a time limit of
16 hours for the entire verification harness. As we can see in @satres the amount of RAM
did end up being the limiting factor when trying to scale the queue size up:
#figure(
  table(
    columns: (auto, auto, auto, auto),
    [*Solver*], [*Queue Size*], [*Time (hh:mm:ss)*], [*RAM (GB)*],
    [Minisat], [16], [Timeout], [-],
    [Cadical], [16], [$5:04:39$], [46],
    [Cadical], [32], [-], [@OOM],
    [Kissat], [16], [$3:53:56$], [18],
    [Kissat], [32], [-], [@OOM],
    [Glucose], [16], [$5:42:35$], [19],
    [Glucose], [32], [-], [@OOM],
  ),
  caption: [Resource Consumption of different SAT solvers],
) <satres>
That being said we did observe that the vast majority of memory in the large queue attempts
were consumed by @CBMC itself, not the SAT solvers. This indicates that if either @CBMC
itself improves or Kani ends up generating a better translation of Rust in the future,
we might be able to run our harness on bigger queue sizes as well.

In addition to this we also checked that the performance of our driver running on real world
hardware is competitive with that reported in the ixy papers. Due to the fact that our Intel 82599
variant only has one cable socket, as opposed to the two socket variant used with ixy, we only
bench marked an reflecting instead of a bidirectional forwarding application. The comparison
between our results, using a batch size of 64 packets, can be seen in @perf. While the speed of
network cables is usually measured in GBit/s the speed of packet processing applications is
measured in @Mpps. The theoretical maximum @Mpps on a single 10 GBit/s line with 64 byte
packets is $14.88$ @Mpps. However ixy is able to reach higher speeds than that as it is
forwarding between two 10 GBit/s lines, for this reason we look at the percentage of the
maximum possible speed to draw a comparison. Note that this comparison is biased towards
verix as ixy has additional bookkeeping to do for the bidirectional forwarding. An additional
difference between our test setups is the CPU. While the ixy test setup ran on a
XEON E3-1230 v2 at both 3.3 and 1.7 GHz our setup ran a Xeon D-1521 running
at 2.4 GHz. As we can see in the data the CPU frequency causes a drastic performance gap
between the two ixy runs. For this reason we attribute at least the majority of the remaining
$approx 12\%$ speed to tie with ixy to CPU frequency and not to the inability of the Rust compiler
to optimize our code.

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    [*Implementation*], [*CPU Freq (GHz)*], [*Absolute (@Mpps)*], [*Max (@Mpps)*], [*Max\%*],
    [ixy C], [3.3], [27.4], [29.76], [92.07],
    [ixy.rs], [3.3], [27.4], [29.76], [92.07],
    [verix], [2.4], [11.9], [14.88], [79.97],
    [ixy C], [1.7], [17.2], [29.76], [57.80],
    [ixy.rs], [1.7], [17.2], [29.76], [57.80],
  ),
  caption: [Performance of ixy vs verix at a batch size of 64]
) <perf>

We thus conclude that we have successfully ported the driver onto L4 at a, most likely,
comparable performance and on top of that succeeded in verifying all the properties
that we set out to at a relatively small but not irrelevant scale.

== Further Work
Three interesting kinds of work that could be built on top of this are relatively clear to us.

First off one could attempt to turn `pc-hal` into a truly generic hardware abstraction layer
like `embedded-hal` and thus achieve portable Rust based user space drivers across multiple
operating systems.

Secondly verix does right now exist mostly in a vacuum, it is not actually useful to other
L4 tasks that wish to interact with the network, in particular VMs. For this purpose one could
implement and potentially verify a virtio adapter that lets verix communicate with other L4 tasks
in order to provided (semi)-verified high performance networking.

Lastly, as already mentioned above, improving the performance of Kani or @CBMC on the problem instances
generated by our harnesses might end up enabling to properly verify the driver at its full queue size in the
future.

= Meeting Anmerkungen
- Verweis auf meinen Code als Github statt im Anhang
