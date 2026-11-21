# ``Swiit/Diagnostic``

What went wrong in a run.

## Overview

A diagnostic has a ``Diagnostic/Kind``, a message and, when it is known, the range of source it is about. A failure that
ran also has a ``Diagnostic/Failure``, which says where it came from and what a script can catch. The article
<doc:ReadingDiagnostics> shows how to read one.

## Topics

### What kind of failure

- ``Kind``
- ``kind``
- ``message``
- ``range``

### A failure that ran

- ``Failure``
- ``failure``
- ``Call``

### Showing one

- ``rendered(in:path:style:)``
- ``Style``

### Making one

- ``init(kind:message:range:)``
- ``fatal(_:cause:)``
- ``runtime(_:thrown:cause:)``
