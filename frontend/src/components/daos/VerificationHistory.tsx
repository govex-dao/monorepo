// components/dao/VerificationHistory.tsx
import { useQuery } from "@tanstack/react-query";
import { CONSTANTS, QueryKey } from "@/constants";
import { Table } from "@radix-ui/themes";

interface VerificationRequest {
  attestation_url: string;
  timestamp: string;
  status: string;
  verification_id: string;
  reject_reason: string | null;
}

interface VerificationHistoryProps {
  daoId: string;
  daoName?: string;
  isSelected: boolean; // New prop to control when to show history
}

export function VerificationHistory({
  daoId,
  daoName,
  isSelected,
}: VerificationHistoryProps) {
  const { data: requests, isLoading } = useQuery<VerificationRequest[]>({
    queryKey: [QueryKey.VerificationHistory, daoId],
    queryFn: async () => {
      const response = await fetch(
        `${CONSTANTS.apiEndpoint}dao/${daoId}/verification-requests`,
      );
      if (!response.ok) {
        throw new Error("Failed to fetch verification history");
      }
      return response.json();
    },
    enabled: isSelected && Boolean(daoId), // Only run query when DAO is selected
  });

  // Don't show anything if no DAO is selected
  if (!isSelected) {
    return null;
  }

  if (isLoading) {
    return (
      <div className="text-sm text-gray-500">
        Loading verification history...
      </div>
    );
  }

  if (!requests?.length) {
    return (
      <div className="text-sm text-gray-500">
        No existing verification requests found
      </div>
    );
  }

  return (
    <div className="mt-4">
      <h3 className="text-lg font-semibold mb-2">{`Verification History for ${daoName}`}</h3>
      <Table.Root variant="surface">
        <Table.Header>
          <Table.Row>
            <Table.ColumnHeaderCell>Date</Table.ColumnHeaderCell>
            <Table.ColumnHeaderCell>Status</Table.ColumnHeaderCell>
            <Table.ColumnHeaderCell>Attestation</Table.ColumnHeaderCell>
            <Table.ColumnHeaderCell>Details</Table.ColumnHeaderCell>
          </Table.Row>
        </Table.Header>

        <Table.Body>
          {requests.map((request, index) => (
            <Table.Row key={`${request.verification_id}-${index}`}>
              <Table.Cell>
                {new Date(Number(request.timestamp)).toLocaleDateString()}
              </Table.Cell>
              <Table.Cell>
                <span
                  className={`px-2 py-1 rounded-full text-xs ${
                    request.status === "pending"
                      ? "bg-yellow-500/20 text-yellow-300"
                      : request.status === "approved"
                        ? "bg-green-500/20 text-green-300"
                        : "bg-red-500/20 text-red-300"
                  }`}
                >
                  {request.status}
                </span>
              </Table.Cell>
              <Table.Cell>
                <a
                  href={request.attestation_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-blue-400 hover:text-blue-300 hover:underline"
                >
                  View
                </a>
              </Table.Cell>
              <Table.Cell>
                {request.reject_reason && (
                  <span className="text-red-400">{request.reject_reason}</span>
                )}
              </Table.Cell>
            </Table.Row>
          ))}
        </Table.Body>
      </Table.Root>
    </div>
  );
}
