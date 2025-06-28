import { Suspense } from "react";
import { DaoView } from "../../routes/DaoView";

export default function DaoPage() {
  return (
    <Suspense fallback={<div>Loading...</div>}>
      <DaoView />
    </Suspense>
  );
}