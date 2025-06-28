import { Suspense } from "react";
import { CreateDashboard } from "../routes/CreateDashboard";

export default function CreatePage() {
  return (
    <Suspense fallback={<div>Loading...</div>}>
      <CreateDashboard />
    </Suspense>
  );
}