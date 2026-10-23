// O13 on the heavy verbs, with the read-only admission gates summarized (HubLeanGates.spec says why that is sound
// for this rule). Same rule as HubLoans.spec, imported, so the two cannot drift apart.

import "HubLoans.spec";
import "HubLeanGates.spec";

use rule aClosedLoanStaysClosed;
