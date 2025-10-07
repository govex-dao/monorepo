import { Routes, Route } from "react-router-dom";
import { Root } from "./routes/root";
import { CreateDashboard } from "@/routes/CreateDashboard";
import { LearnDashboard } from "@/routes/LearnDashboard";
import { TradeDashboard } from "@/routes/TradeDashboard";
import { ProposalView } from "@/routes/ProposalView";
import { DaoView } from "@/routes/DaoView";

export function App() {
  return (
    <Routes>
      <Route path="/" element={<Root />}>
        <Route index element={<TradeDashboard />} />
        <Route path="create" element={<CreateDashboard />} />
        <Route path="learn" element={<LearnDashboard />} />
        <Route path="trade/:proposalId" element={<ProposalView />} />
        <Route path="dao/:daoId" element={<DaoView />} />
      </Route>
    </Routes>
  );
}