#import "template.typ": thesis, sourcecode

#show: thesis.with(
    title: "verix: A Verified Rust ix(4) driver",
    authors: (
      (
        name: "Henrik Böving", 
        email: "henrik_boeving@genua.de", 
        affiliation: "genua GmbH", 
      ),
    ),
    abstract: lorem(70),
    paper-size: "a4",
    bibliography-file: "thesis.bib",
    glossary: (
        (key: "NIC", short: "NIC", long: "Network Interface Card"),
        (key: "BMC", short: "BMC", long: "Bounded Model Checking"),
        (key: "BAR", short: "BAR", long: "Base Address Register")
    )
)

// TODO: do I want to use miri as well?

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
- The model sends all packets that the driver is told to send
#pagebreak()

= Technologies
== Rust
#sourcecode[```rust
fn main() {
  println!("Hello world");
}
```]

In this chapter, I just want to demonstrate the Rust features that we are
going to use, precisely to the extent that I am going to use them:
- Memory Safety via Borrow Checker
  - borrow checking rules
  - RefCell
  - Rc
  - custom Drop
- Trait System:
  - interface replacement
  - associated types
  - constraints
- Macro System
  - declarative macros
  - grammar style declarative macros
- const generics
  - just the very basics, we only use this feature in one place
== L4
- Microkernel concept
  - Capabilities
  - Everything in userspace
- APIs that we use:
  - VBus/IO
  - Dataspaces
== Kani
- general idea: Rust -> CBMC -> SMT
- show the 3 core features:
  - any
  - assume
  - loop unwinding
== Intel 82599
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
- show how traits map to l4 concepts
- custom Drop to free resources in the kernel
== verix
- ixy knockoff
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
