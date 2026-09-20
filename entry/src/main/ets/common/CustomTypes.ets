export enum DialogType {
  NORMAL,
  SHEET,
  FULL_SCREEN
}

export enum TextType {
  PLAIN,
  LINK,
  ACTION
}

export interface PrivacyText {
  text: string;
  type: TextType;
  href?: string;
  onAction?: Callback<void>;
  color?: ResourceColor;
  fontSize?: Length;
  fontWeight?: FontWeight | number | string;
}

export type PrivacyDocument = PrivacyText[];
