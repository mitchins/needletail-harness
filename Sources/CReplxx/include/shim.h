// CReplxx shim: exposes the vendored replxx C API (include/replxx.h,
// upstream commit 1f149bfe20bf6e49c1afd4154eaf0032c8c2fda2, licence in
// replxx/LICENSE.md) to Swift. The Swift boundary sees only the C API;
// C++ interoperability stays inside this target.
#ifndef NEEDLETAIL_CREPLXX_SHIM_H
#define NEEDLETAIL_CREPLXX_SHIM_H
#include "../replxx/replxx.h"
#endif
