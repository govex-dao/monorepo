import { Suspense } from "react";
import { TradeDashboard } from "./routes/TradeDashboard";

export default function HomePage() {
  return (
    <Suspense fallback={<div>Loading...</div>}>
      <TradeDashboard />
    </Suspense>
  );
}