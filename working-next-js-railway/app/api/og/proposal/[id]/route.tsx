import { ImageResponse } from '@vercel/og';
import { NextRequest } from 'next/server';
import { CONSTANTS } from '../../../../constants';

export const runtime = 'edge';

const STATES: Record<number, { label: string; color: string }> = {
  0: { label: 'Pending', color: '#6b7280' },
  1: { label: 'Review', color: '#f59e0b' },
  2: { label: 'Trading', color: '#3b82f6' },
  3: { label: 'Completed', color: '#10b981' },
  4: { label: 'Cancelled', color: '#ef4444' },
};

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const { id } = await params;
    
    // Fetch proposal data
    const response = await fetch(
      `${CONSTANTS.apiEndpoint}proposals/${id}`,
      { next: { revalidate: 120 } }
    );
    
    if (!response.ok) {
      throw new Error('Failed to fetch proposal data');
    }
    
    const proposal = await response.json();
    
    if (!proposal) {
      throw new Error('Proposal not found');
    }
    
    const state = STATES[proposal.current_state] || STATES[0];
    
    return new ImageResponse(
      (
        <div
          style={{
            height: '100%',
            width: '100%',
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'flex-start',
            justifyContent: 'space-between',
            backgroundColor: '#1f2937',
            fontFamily: 'system-ui',
            padding: '60px',
          }}
        >
          {/* Background pattern */}
          <div
            style={{
              position: 'absolute',
              top: 0,
              left: 0,
              right: 0,
              bottom: 0,
              backgroundImage: 'radial-gradient(circle at 1px 1px, #374151 1px, transparent 1px)',
              backgroundSize: '40px 40px',
              opacity: 0.3,
            }}
          />
          
          {/* Header */}
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              width: '100%',
              alignItems: 'flex-start',
            }}
          >
            <div
              style={{
                display: 'flex',
                flexDirection: 'column',
                gap: '16px',
              }}
            >
              {/* DAO Name */}
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '12px',
                }}
              >
                {proposal.dao_icon && (
                  <img
                    src={proposal.dao_icon}
                    alt=""
                    width={40}
                    height={40}
                    style={{
                      borderRadius: '50%',
                    }}
                  />
                )}
                <div
                  style={{
                    fontSize: '24px',
                    color: '#9ca3af',
                    fontWeight: '600',
                  }}
                >
                  {proposal.dao_name}
                </div>
              </div>
              
              {/* State badge */}
              <div
                style={{
                  display: 'inline-flex',
                  backgroundColor: state.color,
                  padding: '8px 16px',
                  borderRadius: '8px',
                  fontSize: '18px',
                  fontWeight: '600',
                  color: '#ffffff',
                }}
              >
                {state.label}
              </div>
            </div>
            
            {/* Winning outcome if completed */}
            {proposal.winning_outcome && proposal.current_state === 3 && (
              <div
                style={{
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'flex-end',
                  gap: '8px',
                }}
              >
                <div
                  style={{
                    fontSize: '18px',
                    color: '#9ca3af',
                  }}
                >
                  Outcome
                </div>
                <div
                  style={{
                    fontSize: '28px',
                    fontWeight: 'bold',
                    color: '#10b981',
                  }}
                >
                  {proposal.winning_outcome}
                </div>
              </div>
            )}
          </div>
          
          {/* Content */}
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: '24px',
              flex: 1,
              justifyContent: 'center',
              width: '100%',
            }}
          >
            {/* Title */}
            <h1
              style={{
                fontSize: '56px',
                fontWeight: 'bold',
                color: '#ffffff',
                lineHeight: 1.2,
                maxWidth: '900px',
              }}
            >
              {proposal.title}
            </h1>
            
            {/* Outcomes */}
            {proposal.outcome_messages && proposal.outcome_messages.length > 0 && (
              <div
                style={{
                  display: 'flex',
                  gap: '20px',
                  flexWrap: 'wrap',
                }}
              >
                {proposal.outcome_messages.slice(0, 3).map((outcome: string, index: number) => (
                  <div
                    key={index}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: '8px',
                      backgroundColor: '#374151',
                      padding: '12px 20px',
                      borderRadius: '8px',
                      fontSize: '20px',
                    }}
                  >
                    <div
                      style={{
                        width: '24px',
                        height: '24px',
                        borderRadius: '50%',
                        backgroundColor: index === 0 ? '#10b981' : '#3b82f6',
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        fontSize: '14px',
                        fontWeight: 'bold',
                        color: '#ffffff',
                      }}
                    >
                      {index + 1}
                    </div>
                    <span
                      style={{
                        color: '#ffffff',
                      }}
                    >
                      {outcome}
                    </span>
                  </div>
                ))}
              </div>
            )}
            
            {/* Liquidity */}
            {(proposal.asset_value || proposal.stable_value) && (
              <div
                style={{
                  display: 'flex',
                  gap: '40px',
                  marginTop: '20px',
                }}
              >
                <div
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    gap: '8px',
                  }}
                >
                  <div
                    style={{
                      fontSize: '18px',
                      color: '#9ca3af',
                    }}
                  >
                    Total Liquidity
                  </div>
                  <div
                    style={{
                      fontSize: '32px',
                      fontWeight: 'bold',
                      color: '#ffffff',
                    }}
                  >
                    {formatLiquidity(proposal.asset_value, proposal.stable_value)}
                  </div>
                </div>
              </div>
            )}
          </div>
          
          {/* Footer */}
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              width: '100%',
              alignItems: 'center',
            }}
          >
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: '10px',
              }}
            >
              <div
                style={{
                  fontSize: '24px',
                  color: '#9ca3af',
                  fontWeight: '600',
                }}
              >
                Govex
              </div>
              <div
                style={{
                  fontSize: '20px',
                  color: '#6b7280',
                }}
              >
                Futarchy on Sui
              </div>
            </div>
            
            {/* Created date */}
            {proposal.created_at && (
              <div
                style={{
                  fontSize: '18px',
                  color: '#6b7280',
                }}
              >
                {new Date(parseInt(proposal.created_at)).toLocaleDateString()}
              </div>
            )}
          </div>
        </div>
      ),
      {
        width: 1200,
        height: 630,
      }
    );
  } catch (error) {
    console.error('Error generating OG image:', error);
    
    // Return a fallback image
    return new ImageResponse(
      (
        <div
          style={{
            height: '100%',
            width: '100%',
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            justifyContent: 'center',
            backgroundColor: '#1f2937',
          }}
        >
          <div
            style={{
              fontSize: '60px',
              fontWeight: 'bold',
              color: '#ffffff',
            }}
          >
            Govex Proposal
          </div>
          <div
            style={{
              fontSize: '24px',
              color: '#9ca3af',
              marginTop: '20px',
            }}
          >
            Futarchy on Sui
          </div>
        </div>
      ),
      {
        width: 1200,
        height: 630,
      }
    );
  }
}

function formatLiquidity(assetValue: string, stableValue: string): string {
  // Simple formatting - you might want to improve this based on decimals
  const totalValue = parseInt(assetValue || '0') + parseInt(stableValue || '0');
  if (totalValue > 1000000000) {
    return `${(totalValue / 1000000000).toFixed(1)}B`;
  } else if (totalValue > 1000000) {
    return `${(totalValue / 1000000).toFixed(1)}M`;
  } else if (totalValue > 1000) {
    return `${(totalValue / 1000).toFixed(1)}K`;
  }
  return totalValue.toString();
}