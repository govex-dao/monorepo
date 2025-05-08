import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator
import numpy as np

def print_hi(name):
    # Plotting the second diagram
    fig, ax = plt.subplots(figsize=(12, 8))
    # Define linewidths
    red_line_thickness = 5.0
    blue_line_thickness = 2 * red_line_thickness # Should be 10.0 as per problem statement, user code says 2*red, which is 10.0.
    blue_dotted_line_thickness = red_line_thickness # 5.0
    green_line_thickness = 5.0 # Thin line for TWAP initial observation
    naive_twap_thickness = 16.0 # For the new dark yellow line

    # Grid points setup
    x_grid_points = np.array([0, 1, 2]) # Grid points at x = 0, 1, 2
    y_grid_points = np.arange(0, 6, 1)
    ax.scatter(np.repeat(x_grid_points, len(y_grid_points)),
               np.tile(y_grid_points, len(x_grid_points)),
               color='dimgray',
               marker='x',
               s=60,
               alpha=0.9,
               label='Grid point',
               zorder=-0.5) # Behind all main lines

    # New Green line: TWAP initial observation
    # zorder=0, this will be behind the new yellow line
    ax.hlines(y=2, xmin=0, xmax=2, color='green', linewidth=green_line_thickness, label='1) TWAP initial observation', zorder=0.5)

    # --- New Dark Yellow Line (Naive approach TWAP accumulation) ---
    # Behind blue and red, but in front of green.
    # Segment 1: from 0-1 at y=2
    ax.hlines(y=2, xmin=0, xmax=1, color='darkgoldenrod', linewidth=naive_twap_thickness,
              label='2) Naive approach TWAP accumulation', zorder=0)
    # Segment 2: from 1-2 at y=3
    ax.hlines(y=3, xmin=1, xmax=2, color='darkgoldenrod', linewidth=naive_twap_thickness,
              zorder=0) # No label for the second segment

    # Blue lines: Starting AMM raw price & after events
    # zorder=1, this will be in front of yellow and green
    ax.hlines(y=2, xmin=0, xmax=0.5, color='dodgerblue', linewidth=blue_line_thickness, label='3) AMM raw price', zorder=1)
    ax.hlines(y=4, xmin=0.5, xmax=1.0, color='dodgerblue', linewidth=blue_line_thickness, zorder=1)
    ax.hlines(y=5, xmin=1.0, xmax=2.0, color='dodgerblue', linewidth=blue_line_thickness, zorder=1)

    # Red lines: Optimized Approach TWAP accumulation per window
    # zorder=1.1, this will be in front of yellow, green, and blue (where they overlap)
    ax.hlines(y=2, xmin=0.0, xmax=0.5, color='crimson', linewidth=red_line_thickness, label='4) Optimized approach TWAP accumulation', zorder=1.1)
    ax.hlines(y=3, xmin=0.5, xmax=1.0, color='crimson', linewidth=red_line_thickness, zorder=1.1)
    ax.hlines(y=3.5, xmin=1.0, xmax=2.0, color='crimson', linewidth=red_line_thickness, zorder=1.1)

    # Blue vertical event lines (dotted)
    # zorder=2, on top of data lines
    ax.vlines(x=[0.5, 1.0], ymin=[2, 4], ymax=[4, 5], color='purple', linewidth=blue_dotted_line_thickness, linestyle='dotted',
              label='Price change events', zorder=0)

    # Annotating events
    # zorder=3, on top of everything
    event_positions = [(0.5, 4.2), (1.0, 5.2)]
    event_labels = ['Buy 1', 'Buy 2']
    for idx, (x_pos, y_pos) in enumerate(event_positions):
        ax.annotate(f'{event_labels[idx]}', xy=(x_pos, y_pos), fontsize=14, color='darkgreen', weight='bold', ha='center', zorder=3)

    # Axis labels and title
    ax.set_xlabel('Time (Windows)', fontsize=18)
    ax.set_ylabel('Price ($)', fontsize=18)
    ax.set_title('Intra step TWAP use for previous base when capping', fontsize=18, weight='bold')

    # Legend placement
    ax.legend(loc='lower right', fontsize=16)

    # Grid, Spines, and Ticks configuration
    ax.grid(False) # Turn off grid lines

    # Spine settings: Make all spines visible (explicitly, good practice)
    ax.spines['top'].set_visible(True)
    ax.spines['right'].set_visible(True)
    ax.spines['bottom'].set_visible(True)
    ax.spines['left'].set_visible(True)

    # --- Tick settings ---
    # Set locators for major and minor ticks
    ax.xaxis.set_major_locator(MultipleLocator(0.5))  # Major ticks at every 0.5 for X-axis
    ax.xaxis.set_minor_locator(MultipleLocator(0.25))  # Minor ticks at every 0.25 for X-axis
    ax.yaxis.set_major_locator(MultipleLocator(1.0))  # Major ticks at every integer for Y-axis
    ax.yaxis.set_minor_locator(MultipleLocator(0.5))  # Minor ticks at every 0.5 for Y-axis

    # Style major ticks
    ax.tick_params(axis='both', which='major', direction='in', length=20, width=1.0, labelsize=16, top=True, right=True,
                     bottom=True, left=True)
    # Style minor ticks
    ax.tick_params(axis='both', which='minor', direction='in', length=10, width=0.5, labelsize=16, top=True, right=True,
                        bottom=True, left=True)

    # Set axis limits
    ax.set_xlim(-0.1, 2.1)
    ax.set_ylim(0, 6)

    # Adjust layout to make space for the description (if any, none in this example but good practice)
    plt.subplots_adjust(bottom=0.1) # Adjusted slightly if needed, original was 0.2
    plt.savefig('intra-twap-graph.png', dpi=300, bbox_inches='tight')  # Save with high DPI and tight bounding box

    plt.show()

if __name__ == '__main__':
    print_hi('PyCharm')