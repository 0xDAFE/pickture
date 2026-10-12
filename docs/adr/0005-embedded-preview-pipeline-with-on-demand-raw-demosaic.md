# Embedded-First Preview Pipeline with On-Demand RAW Demosaic on Remote Storage

To guarantee instantaneous, low-latency culling over network shares and slow media, Pickture strictly decodes container-embedded previews (via byte-range reads) by default, even when zooming to 100% (1:1) in the Filmstrip canvas. Pickture will never automatically stream and demosaic full 50–80 MB RAW files over remote connections unless the user explicitly triggers an on-demand "Load Full RAW" action for critical focus inspection.
