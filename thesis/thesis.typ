#import "template.typ": thesis, sourcecode

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
        (key: "BAR", short: "BAR", long: "Base Address Register")
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
- #cite("witowski2007drivers") and #cite("ball2004slam") are mostly concerned with the driver interactions with the rest of the kernel
  as well as the absence of C-related issues
- #cite("more2021hol4drivers") implements a verified monitor for interactions of a real driver with the @NIC instead of verifying the driver itself. While this means that bad interactions with the hardware can now be detected at runtime this still has to be done in a way that is
preventing the driver from its regular operations which usually means a crash.

// Explain, in one sentence, how you tackled the research question.
In this thesis, we are going to show that formally verifying the interaction of a driver with the @NIC is possible by implementing a model of the target hardware and using @BMC to prove that they cooperate correctly.

// How did you go about doing the research that follows from your big idea?
To show that the concept is viable in practice we are going to implement a driver for the widely used Intel 82559ES @NIC.
This is going to happen on the L4.Fiasco microkernel so misbehavior of the driver can barely affect the system as a whole in the first place.
On top of that we are going to use the Rust programming language which guarantees additional safety properties out of the box.
The driver and model themselves are going to be developed using a custom Rust eDSL in the spirit of svd2rust to make correct peripheral access easier.
We are then going to show, using the kani BMC, that the driver correctly cooperates with a model of the 82559ES, where correctly means that:
- The driver doesn't panic
- The driver doesn't put the model into an undefined state
- The driver receives all packets that are received by the model
- The driver correctly instructs the model to send packets
#pagebreak()

= L4.Fiasco
TODO: Ask people at work what to cite for L4
- Microkernel concept
  - Capabilities
  - Everything in userspace
- APIs that we use:
  - VBus/IO
  - Dataspaces
= Rust
We chose to use the Rust programming language for the entire implementation
due to three key factors:
1. It is memory safe by default while at the same time being competitive with
   the likes of C/C++ in terms of performance.
2. If necessary it still allows us to break out into a memory unsafe subset of
   language, unlike most memory safe languages such as Java.
3. It already has partial support on our target platform, L4.Fiasco.

In this section we aim to give an overview over the important Rust features
that we are going to use. For a more complete overview of the Rust language
refer to #cite("rustbook").

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
pub trait Add<Rhs, Out> {
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
able to figure out the output on its own. This would force users to put explicit
type annotations in order to make the instance search succeed. In order to make
using this trait easier we can use so called associated types:

#sourcecode[```rust
pub trait Add<Rhs> {
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
variables. This means that while we could've previously written instances like
`Add<Duration, Time> for Time` and `Add<Duration, Duration> for Time` the new design
doesn't allow this as we would have two instance of the form `Add<Duration> for Time`.
While associated types take a bit of flexibility away from the programmer they do
allow Rust to start instance search without being known from type inference.
Whether to use generic or associated types thus comes down to a usability
(through type inference) vs flexibility (through additional permitted instances) trade off.

== Macros
#cite("rustmacrobook")
- Macro System
  - declarative macros
  - grammar style declarative macros
= Kani
- Source: #cite("kani")
- general idea: Rust -> CBMC -> SMT
- show the core features:
  - any
  - assume
  - loop unwinding
  - mocking
- Mention the custom flags we use
= Intel 82599
#cite("intel:82599")
- general PCI setup:
  - interaction with the PCI config space
  - map BAR
- 82599 specific stuff:
  - setup procedure:
    - reset
    - get link
    - initialize queues
  - operation
    - descriptors
    - RX / TX queues
#pagebreak()

= verix
== Architecture
- image of how components connect
== pc-hal
- show the traits
  - this will reference all of the trait stuff from above
- show the MMIO macro
  - this will reference the macro and the const generic stuff
== pc-hal-l4
#cite("humendal4")
- show how traits map to l4 concepts
- custom Drop to free resources in the kernel
== verix
- ixy knockoff: #cite("emmerichixy") #cite("ellmannixy")
- main differences:
  - written against a generic interface (implemented for L4 right now)
  - uses far less unsafe for memory-mapped structures
  - follows the datasheet more anally in some sections
- show the verix side of the RX/TX procedure, in particular, the memory management
  - This will use the Rc/RefCell stuff that we introduced above
== mix
- explain the model itself
- how the model hooks into verix
- What does it mean for our driver to be correct? I think the answer is 3 main properties
  1. Device discovery:
    - What: The driver finds the NIC and maps BAR0 correctly without violating any operating system requirements
    - How: We write the model such that it throws errors in the same way as L4 describes in their documentation.
      We then use BMC to show that for any valid system configuration the driver ends up mapping correctly
  2. Device initialization:
    - What: The driver should set up the NIC correctly. Correctly here means the following:
      1. Do not set any reserved fields or invalid value ranges that potentially cause UB
      2. Upon enabling a component we assert that the component configuration is valid and the one we expect
    - How: We model the IO memory of the device as a state machine with 9 states according to 4.6.1
      In each state writes to the registers concerned with the current initialization step are legal.
      There is always a "finalization" register that enables the subcomponent. Upon writes to this finalization
      register tow things happen:
      1. The configuration is asserted to be valid and correct
      2. The state is switched to the next initialization step
      This loop continues until we eventually are done initializing
  3. Device operation:
    - What: Here we are mainly concerned with maintaining invariants of the RX/TX queueing structure
      for the entire duration of the driver's runtime. Since this is forever we effectively take an
      inductive approach here:
      1. show that after device initialization we end up in a valid queue configuration
      2. show that given any valid queue configuration we can do a single cycle in the processing loop that:
        - doesn't panic
        - processes packets correctly
        - ends up in a valid queue configuration
    - How:
      - in order to check whether packets were correctly transmitted we:
        - inject as many as required and possible of them into the RX descriptor queue + the shared memory buffer
        // TODO: make this idea more precise
        - assert that after a run the correct chunk (depending on the state of the queue if it was previously filled with
          packets already we get some of those as well, the semantics of "filling" the queue have to be a little more elaborate
          here, basically the initial queue has 0-n packets and then we add m packets (up to a max of n + M < num_valid_rx_descriptors) on top)
          of packets ended up in the TX queue (if possible) and the pointer was advanced
      - The system state as far as I am concerned consists of:
        - The RX/TX queue data structures on the OS side. The main thing of interest here is:
          - the rx/tx used buffers
          - the rx/tx index
          - the tx clean index
        - The mempool on the OS side. The main thing of interest here is:
          - the free list
        - The RX/TX queue state on the NIC side. The main thing of interest here is:
          - RX/TX head/tail pointers
        - The DMA state:
          - the descriptor queues + the packet buffer
      - I claim that we are in a valid state if:
        - The list of mempool buffers in the used lists of RX/TX and in the free list of allocators has no duplicates and contains all mempools
        - The TX queue (both on the OS and the NIC side) is in a valid state, that is:
          - TODO
        - The RX queue (both on the OS and the NIC side) is in a valid state, that is:
          - Q[RDH..RDT] = valid rx_read_desc
          - Q[RX_IDX..RDH] = valid rx_wb_desc
          - valid rx_read_desc means:
            - Packet Buffer Address is the pointer corresponding to the buffer
            - DD = 0
          - valid rx_wb_desc means:
            - DD = 1
            - EOP = 1
            - PKT_LEN is correct

- note that it is particularly important to split stuff up, throwing the entire driver
  into the model checker at once is not viable.

#pagebreak()

= Conclusion
== Results
- verification
- performance
  - not only mbit/s but also latency like ixy, in general structure this analysis like ixy
== Further Work
- turn pc-hal into something general enough to run as e.g. a Linux userspace driver
- add a virtio backend to make it useful for other applications on L4
  - potential for virtio verification as already partially done with kani
