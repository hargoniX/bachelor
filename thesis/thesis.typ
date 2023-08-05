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
    )
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
- The model sends all packets that the driver is told to send
#pagebreak()

= Technologies
== Rust
#sourcecode[```rust
fn main() {
  println!("Hello world");
}
```]
- Memory Safety via Borrow Checker
  - Custom Drop 
- Trait System
- Macro System
  - Declarative Macros
- const generics
== L4
- Microkernel concept
  - Capabilities
  - Everything in userspace
- APIs that we use:
  - VBus/IO
  - Dataspaces
  - Interrupts
== Kani
- Model Checking
- Used for Unsafe code before
- CBMC/SMT
== Intel 82599

#pagebreak()

= verix
== Architecture
- image of how components connect
== pc-hal
- show the traits
== pc-hal-l4
- show how traits map to l4 concepts
- custom Drop's to free resources in the kernel
== verix
- ixy knockoff
- main differences:
  - written against a generic interface (implemented for L4 right now)
  - uses far less unsafe for memory mapped structures
  - follows the datasheet more anally in some sections
- go through the initialization and rx/tx procedure to explain more precisely what we want to verify
== mix
- explain the model itself
- how the model hooks into verix
- how we express the properties

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
