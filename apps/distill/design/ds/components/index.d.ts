import type * as React from 'react';
/** Theme.swift PrimaryButton. */
export interface PrimaryButtonProps { title: string; systemImage?: string; size?: 'regular' | 'small' | 'mini'; enabled?: boolean; onClick?: () => void }
export declare function PrimaryButton(props: PrimaryButtonProps): React.ReactElement;
/** Theme.swift Pill. fill and ink take a colour token name (peachTint) or a colour. */
export interface PillProps { text: string; fill?: string; ink?: string; size?: 'regular' | 'small'; systemImage?: string; busy?: boolean; stroke?: boolean; dashed?: boolean }
export declare function Pill(props: PillProps): React.ReactElement;
declare global { interface Window { Distill: { PrimaryButton: typeof PrimaryButton; Pill: typeof Pill } } }
