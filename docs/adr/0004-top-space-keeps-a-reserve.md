# The top space keeps an unlisted reserve

Every space under the top owns only part of the storage file, and Settings shows both the reserved size and the free room in this space. In a child with no spaces under it, the room that doesn't add up showed that a space sits above it. So the top space now keeps a third of the file as an unlisted reserve. After setup gives the everyday space half the top's free room, both spaces see the same free room, and every space, the top included, sees less free room than the file holds.

The top draws on the reserve only when its listed room runs out, so nothing is lost. Each space can also hold at most four spaces directly under it, the top included, so "No more spaces fit under this one" comes at the same point in the top and in the everyday space.

## Considered Options

- **Hide the reserved size inside spaces**: iPhone Storage in iOS Settings still shows the file size, so the gap stays visible.
- **A random reserve**: no better for the default setup, where a third already makes the top and the everyday space look the same.

## Consequences

- Files made before this change have no reserve; only new setups get one.
- A space two or more levels down has fewer spare slots, so it fits fewer than four spaces under it. Finding that out means creating spaces until the limit.
- With a forced code and a copy of the file, a forensic lab can decrypt that space's header and see that its room and slots are smaller than the file. The tree (0001) accepts this.
