import { Suspense } from "react";
import { ProposalView } from "../../routes/ProposalView";

export default function ProposalPage() {
  return (
    <Suspense fallback={<div>Loading...</div>}>
      <ProposalView />
    </Suspense>
  );
}