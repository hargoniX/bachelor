#let title = "verix: A Verified Rust ix(4) driver"
#let author = "Henrik Böving"

#set par(justify: true)

#set document(
    title: title,
    author: author
)
#set page(numbering : "1")
// Title page.

#align(center)[
  #text(2em, weight: 700, title)
  
  #text(1.00em, author)
]

#v(10pt)

// Inspired by: https://grosser.science/howtos/paper-writing
// Introduction. In one sentence, what’s the topic?
As computer systems are becoming increasingly ubiquitous and complex both the negative impact of bugs as well as the likelihood of them occurring are increasing.
Because of this, catching bugs with potentially catastrophic effects before they happen is becoming more and more important.
These bugs usually occur in one of two fashions, either in the implementation of some algorithm or data structure or in the interaction of a computer system with the outside world.
This thesis is mostly concerned with the latter kind.

// State the problem you tackle
Networking represents a key interaction point with the outside world for most contemporary computer systems, it usually involves three key components:
- the NIC driver
- the network stack
- networking application
While verifying network stacks and applications requires substantial resources due to their complexity, verification of NIC drivers is much more approachable since they have only two jobs
1. Setting up the NIC
2. Handling the receiving and transmission of packets.

// Summarize why nobody else has adequately answered the research question yet.
To our knowledge, there do not exist network drivers whose interaction with the NIC itself has been formally verified.
Instead, the focus is usually put on the interaction with other parts of the operating system or proving the absence of C-based issues:
- #cite("witowski2007drivers") and #cite("ball2004slam") are mostly concerned with the driver interactions with the rest of the kernel
- #cite("more2021hol4drivers") writes a verified monitor for interactions of a real driver with the NIC instead of verifying the driver itself
    
// Explain, in one sentence, how you tackled the research question.
In this thesis, we are going to show that formally verifying the interaction of a driver with the NIC is possible by implementing a model of the target hardware and using BMC to prove that they cooperate correctly.

// How did you go about doing the research that follows from your big idea?
To show that the concept is viable in practice we are going to implement a driver for the widely used Intel 82559ES NIC.
This is going to happen on the L4.Fiasco microkernel so misbehavior of the driver can barely affect the system as a whole in the first place.
On top of that we are going to use the Rust programming language which guarantees additional safety properties out of the box.
The driver and model themselves are going to be developed using a custom Rust eDSL in the spirit of svd2rust to make correct peripheral access easier.
We are then going to show, using the kani BMC, that the driver correctly cooperates with a model of the 82559ES, where correctly means that:
- The driver doesn't panic
- The driver doesn't put the model into an undefined state
- The driver receives all packets that are received by the model
- The model sends all packets that the driver is told to send

#bibliography("bib.bib")