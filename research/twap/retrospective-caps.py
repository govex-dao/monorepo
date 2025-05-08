import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator
import numpy as np


def print_hi(name):
    # Plotting the diagram
    fig, ax = plt.subplots(figsize=(10, 6))  # Original figsize

    # Define linewidths (consistent with reference where applicable)
    blue_line_thickness = 10.0  # For AMM raw price (blue)
    thin_red_line_thickness = 5.0  # For Optimized Approach TWAP accumulation
    green_line_thickness = 5.0  # For TWAP initial observation
    blue_dotted_line_thickness = 5.0  # For event lines, consistent with reference style's red_line_thickness
    naive_twap_thickness = 16.0 # For Naive approach TWAP accumulation

    # Grid points setup
    x_grid_plot = np.array([0, 1, 2, 3])  # x values for grid points
    y_grid_plot = np.arange(0, 6, 1)  # y values for grid points
    ax.scatter(np.repeat(x_grid_plot, len(y_grid_plot)),
               np.tile(y_grid_plot, len(x_grid_plot)),
               color='dimgray',
               marker='x',
               s=60,
               alpha=0.9,
               label='Grid point')

    # --- New Green Line (TWAP initial observation) ---
    # Plotted at y=2 from x=0 to x=3
    ax.hlines(y=2, xmin=0, xmax=3, color='green', linewidth=green_line_thickness, label='1) TWAP initial observation',
              zorder=0) # zorder=0, so yellow will be behind this

    # --- New Dark Yellow Line (Naive approach TWAP accumulation) ---
    # Plotted at y=2 from x=0 to x=1
    ax.hlines(y=2, xmin=0, xmax=1, color='darkgoldenrod', linewidth=naive_twap_thickness,
              label='2) Naive approach TWAP accumulation', zorder=-1) # Dark yellow, zorder to be behind
    # Plotted at y=3 from x=1 to x=3
    ax.hlines(y=3, xmin=1, xmax=3, color='darkgoldenrod', linewidth=naive_twap_thickness,
              zorder=-1) # No label for the second segment to avoid duplicate legend

    # --- AMM Price Lines (Blue) ---
    # No AMM line from x=0 to x=1.
    # AMM raw price at y=4 from x=1 to x=3.
    ax.hlines(y=4, xmin=1, xmax=3, color='dodgerblue', linewidth=blue_line_thickness, label='3) AMM raw price', zorder=1)

    # --- Thin Red Lines (Optimized Approach TWAP accumulation) ---
    # Segment from x=1 to x=2 at y=3
    ax.hlines(y=3, xmin=1, xmax=2, color='crimson', linewidth=thin_red_line_thickness,
              label='4) Optimized approach TWAP accumulation', zorder=1.5) # zorder between green/yellow and blue
    # Segment from x=2 to x=3 at y=4
    ax.hlines(y=4, xmin=2, xmax=3, color='crimson',
              linewidth=thin_red_line_thickness, zorder=1.5)  # No label here to avoid duplicate legend entry

    # --- Vertical Event Lines (Dotted Blue) & Annotations ---
    event_x_positions = [1.0]
    event_y_starts = [2.0]  # Assumed AMM price before event (or TWAP initial)
    event_y_ends = [4.0]  # AMM price after event (start of blue line)

    ax.vlines(x=event_x_positions,
              ymin=event_y_starts,
              ymax=event_y_ends,
              color='purple',
              linewidth=blue_dotted_line_thickness,
              linestyle='dotted',
              label='Price change events', zorder=0) # zorder higher

    # Annotating the event
    event_annotation_positions = [(1.0, 4.2), (2.8, 4.2 )]  # y-pos slightly above the new price
    event_annotation_labels = ['Buy 1', 'Read TWAP']
    for idx, (x_pos, y_pos) in enumerate(event_annotation_positions):
        ax.annotate(f'{event_annotation_labels[idx]}',
                    xy=(x_pos, y_pos),
                    fontsize=14,
                    color='darkgreen',  # As per reference graph annotation style
                    weight='bold',
                    ha='center',
                    zorder=3) # zorder highest for annotations

    # Axis labels and title (from original script)
    ax.set_xlabel('Time (Windows)', fontsize=18)
    ax.set_ylabel('Price ($)', fontsize=18)
    ax.set_title('Retrospective TWAP step cap adjustment per window', fontsize=18, weight='bold')

    # Custom legend at the bottom right
    ax.legend(loc='lower right', fontsize=14)

    # Grid settings (grid is off as per original script)
    ax.grid(False)

    # Spine settings: Make all spines visible
    ax.spines['top'].set_visible(True)
    ax.spines['right'].set_visible(True)
    ax.spines['bottom'].set_visible(True)  # Often True by default
    ax.spines['left'].set_visible(True)  # Often True by default

    # --- Tick settings ---
    # Set locators for major and minor ticks to distinguish integers and half-integers
    # For X-axis:
    ax.xaxis.set_major_locator(MultipleLocator(1.0))  # Major ticks at every integer (0, 1, 2, ...)
    ax.xaxis.set_minor_locator(MultipleLocator(0.5))  # Minor ticks at every half-integer (0.5, 1.5, ...)

    # For Y-axis:
    ax.yaxis.set_major_locator(MultipleLocator(1.0))  # Major ticks at every integer
    ax.yaxis.set_minor_locator(MultipleLocator(0.5))  # Minor ticks at every half-integer

    # Style major ticks (integers) - make them "bigger"
    # These tick marks will appear at integer values.
    ax.tick_params(axis='both', which='major', direction='in',
                     length = 20, width = 1.0, labelsize=16,  # Major ticks are longer (length=7) and thicker (width=1.0)
                     top = True, right = True, bottom = True, left = True)  # Show tick marks on all spines

    # Style minor ticks (half-integers) - make them smaller
    # These tick marks will appear at half-integer values.
    ax.tick_params(axis='both', which='minor', direction='in',
                     length = 10, width = 0.5, labelsize=16,  # Minor ticks are shorter (length=3.5) and thinner (width=0.5)
                     top = True, right = True, bottom = True, left = True)  # Show tick marks on all spines

    # Set axis limits
    ax.set_xlim(-0.1, 3.1)  # Show 0 to 3 clearly
    ax.set_ylim(0, 6)  # Original y-limit

    # Adjust layout to make space for the description
    plt.subplots_adjust(bottom=0.20)
    plt.savefig('retrospective-twap-graph.png', dpi=300, bbox_inches='tight')  # Save with high DPI and tight bounding box
    plt.show()


# Press the green button in the gutter to run the script.
if __name__ == '__main__':
    print_hi('PyCharm')