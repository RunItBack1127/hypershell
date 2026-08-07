import {
  ActionGroup,
  Alert,
  Button,
  Content,
  Form,
  FormGroup,
  FormHelperText,
  HelperText,
  HelperTextItem,
  MenuToggle,
  PageSection,
  Select,
  SelectList,
  SelectOption,
  TextInputGroup,
  TextInputGroupMain,
  TextInput,
  Title,
  type MenuToggleElement,
} from "@patternfly/react-core";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useRef, useState } from "react";
import { Controller, useForm, type Control } from "react-hook-form";
import { FormattedMessage, useIntl } from "react-intl";
import { z } from "zod";

import { useGatewayUi } from "../gateway-ui-provider";
import { messages } from "../messages";
import { gatewayListQueryRoot, gatewayQueryKey } from "./gateway-data";

export interface GatewayCreatePageProps {
  onCreated?: (gatewayId: string) => Promise<void> | void;
}

interface GatewayFormValues {
  name: string;
  namespace: string;
  releaseId: string;
}

const fieldNames = [
  "name",
  "namespace",
  "releaseId",
] as const satisfies readonly (keyof GatewayFormValues)[];

interface GatewayTextFieldProps {
  control: Control<GatewayFormValues>;
  fieldId: string;
  isDisabled: boolean;
  label: string;
  name: keyof GatewayFormValues;
}

interface GatewayReleaseSelectProps {
  control: Control<GatewayFormValues>;
  isDisabled: boolean;
  releases: readonly {
    id: string;
    image: string;
    name: string;
  }[];
}

function GatewayReleaseSelect({
  control,
  isDisabled,
  releases,
}: GatewayReleaseSelectProps) {
  const intl = useIntl();
  const [isOpen, setIsOpen] = useState(false);
  const [inputValue, setInputValue] = useState("");
  const [filterValue, setFilterValue] = useState("");
  const [focusedItemIndex, setFocusedItemIndex] = useState<number | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const filteredReleases = useMemo(() => {
    const query = filterValue.trim().toLocaleLowerCase();
    if (!query) {
      return releases;
    }
    return releases.filter(
      (release) =>
        release.name.toLocaleLowerCase().includes(query) ||
        release.image.toLocaleLowerCase().includes(query),
    );
  }, [filterValue, releases]);

  const closeMenu = () => {
    setIsOpen(false);
    setFocusedItemIndex(null);
  };

  return (
    <Controller
      control={control}
      name="releaseId"
      render={({ field, fieldState }) => {
        const selectedRelease = releases.find(
          (release) => release.id === field.value,
        );
        const selectRelease = (releaseId: string) => {
          const release = releases.find((item) => item.id === releaseId);
          if (!release) {
            return;
          }
          field.onChange(release.id);
          setInputValue(release.name);
          setFilterValue("");
          closeMenu();
        };
        const moveFocus = (direction: 1 | -1) => {
          if (filteredReleases.length === 0) {
            return;
          }
          setFocusedItemIndex((current) => {
            if (current === null) {
              return direction === 1 ? 0 : filteredReleases.length - 1;
            }
            return (
              (current + direction + filteredReleases.length) %
              filteredReleases.length
            );
          });
        };
        const toggle = (toggleRef: React.Ref<MenuToggleElement>) => (
          <MenuToggle
            isDisabled={isDisabled}
            isExpanded={isOpen}
            isFullWidth
            onClick={() => {
              setIsOpen((open) => !open);
              inputRef.current?.focus();
            }}
            ref={toggleRef}
            variant="typeahead"
          >
            <TextInputGroup isPlain>
              <TextInputGroupMain
                aria-activedescendant={
                  focusedItemIndex === null
                    ? undefined
                    : `gateway-release-option-${String(focusedItemIndex)}`
                }
                aria-autocomplete="list"
                aria-controls="gateway-release-options"
                aria-describedby={
                  fieldState.error ? "gateway-release-helper" : undefined
                }
                aria-expanded={isOpen}
                aria-label={intl.formatMessage(messages.gatewayRelease)}
                autoComplete="off"
                id="gateway-release"
                innerRef={inputRef}
                disabled={isDisabled}
                onBlur={field.onBlur}
                onChange={(_event, value) => {
                  setInputValue(value);
                  setFilterValue(value);
                  setFocusedItemIndex(null);
                  setIsOpen(true);
                  if (value !== selectedRelease?.name) {
                    field.onChange("");
                  }
                }}
                onClick={() => {
                  setIsOpen(true);
                }}
                onKeyDown={(event) => {
                  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                    event.preventDefault();
                    setIsOpen(true);
                    moveFocus(event.key === "ArrowDown" ? 1 : -1);
                  } else if (
                    event.key === "Enter" &&
                    isOpen &&
                    focusedItemIndex !== null
                  ) {
                    event.preventDefault();
                    const release = filteredReleases[focusedItemIndex];
                    if (release) {
                      selectRelease(release.id);
                    }
                  }
                }}
                placeholder={intl.formatMessage(messages.selectGatewayRelease)}
                role="combobox"
                value={inputValue}
              />
            </TextInputGroup>
          </MenuToggle>
        );

        return (
          <FormGroup
            fieldId="gateway-release"
            isRequired
            label={intl.formatMessage(messages.gatewayRelease)}
          >
            <Select
              id="gateway-release-select"
              isOpen={isOpen}
              onOpenChange={(open) => {
                if (!open) {
                  closeMenu();
                }
              }}
              onSelect={(_event, value) => {
                if (typeof value === "string") {
                  selectRelease(value);
                }
              }}
              selected={field.value}
              toggle={toggle}
              variant="typeahead"
            >
              <SelectList id="gateway-release-options">
                {filteredReleases.length === 0 ? (
                  <SelectOption
                    isAriaDisabled
                    value="gateway-release-no-results"
                  >
                    {intl.formatMessage(messages.noMatchingGatewayReleases)}
                  </SelectOption>
                ) : (
                  filteredReleases.map((release, index) => (
                    <SelectOption
                      description={release.image}
                      id={`gateway-release-option-${String(index)}`}
                      isFocused={focusedItemIndex === index}
                      key={release.id}
                      value={release.id}
                    >
                      {release.name}
                    </SelectOption>
                  ))
                )}
              </SelectList>
            </Select>
            {fieldState.error ? (
              <FormHelperText>
                <HelperText>
                  <HelperTextItem id="gateway-release-helper" variant="error">
                    {fieldState.error.message}
                  </HelperTextItem>
                </HelperText>
              </FormHelperText>
            ) : null}
          </FormGroup>
        );
      }}
    />
  );
}

function GatewayTextField({
  control,
  fieldId,
  isDisabled,
  label,
  name,
}: GatewayTextFieldProps) {
  return (
    <Controller
      control={control}
      name={name}
      render={({ field, fieldState }) => (
        <FormGroup fieldId={fieldId} isRequired label={label}>
          <TextInput
            aria-describedby={
              fieldState.error ? `${fieldId}-helper` : undefined
            }
            id={fieldId}
            isDisabled={isDisabled}
            isRequired
            name={field.name}
            onBlur={field.onBlur}
            onChange={(_event, value) => {
              field.onChange(value);
            }}
            validated={fieldState.error ? "error" : "default"}
            value={field.value}
          />
          {fieldState.error ? (
            <FormHelperText>
              <HelperText>
                <HelperTextItem id={`${fieldId}-helper`} variant="error">
                  {fieldState.error.message}
                </HelperTextItem>
              </HelperText>
            </FormHelperText>
          ) : null}
        </FormGroup>
      )}
    />
  );
}

export function GatewayCreatePage({ onCreated }: GatewayCreatePageProps = {}) {
  const intl = useIntl();
  const { gateways, navigation } = useGatewayUi();
  const queryClient = useQueryClient();
  const requiredMessage = intl.formatMessage(messages.requiredField);
  const schema = useMemo(() => {
    const requiredString = z.string().trim().min(1, requiredMessage);

    return z.object({
      name: requiredString,
      namespace: requiredString,
      releaseId: requiredString,
    });
  }, [requiredMessage]);
  const { control, handleSubmit, setError } = useForm<GatewayFormValues>({
    defaultValues: {
      name: "",
      namespace: "openshell",
      releaseId: "",
    },
  });

  const gatewayReleases = useQuery({
    queryFn: ({ signal }) => gateways.listGatewayReleases(signal),
    queryKey: ["gateway-releases", "provision-options"],
    staleTime: 60_000,
  });

  const createGateway = useMutation({
    mutationFn: (values: GatewayFormValues) => {
      return gateways.provisionGateway(values);
    },
    onSuccess: async (gateway) => {
      queryClient.setQueryData(gatewayQueryKey(gateway.id), gateway);
      await queryClient.invalidateQueries({
        queryKey: gatewayListQueryRoot,
      });
      if (onCreated) {
        await onCreated(gateway.id);
      } else {
        await navigation.navigate(navigation.detailHref(gateway.id));
      }
    },
  });

  const submit = handleSubmit((values) => {
    const result = schema.safeParse(values);
    if (!result.success) {
      for (const issue of result.error.issues) {
        const fieldName = issue.path[0];
        if (fieldNames.includes(fieldName as keyof GatewayFormValues)) {
          setError(fieldName as keyof GatewayFormValues, {
            message: issue.message,
            type: "validate",
          });
        }
      }
      return;
    }

    createGateway.mutate(result.data);
  });

  return (
    <>
      <PageSection hasBodyWrapper={false}>
        <Content>
          <Title headingLevel="h1" size="2xl">
            <FormattedMessage {...messages.provisionGateway} />
          </Title>
          <p>
            <FormattedMessage {...messages.provisionGatewayDescription} />
          </p>
        </Content>
      </PageSection>
      <PageSection hasBodyWrapper={false} isFilled variant="secondary">
        <Form
          aria-label={intl.formatMessage(messages.provisionGateway)}
          isWidthLimited
          onSubmit={(event) => void submit(event)}
        >
          {createGateway.isError ? (
            <Alert
              isInline
              title={intl.formatMessage(messages.gatewayProvisionError)}
              variant="danger"
            >
              <FormattedMessage {...messages.gatewayProvisionErrorBody} />
            </Alert>
          ) : null}
          {gatewayReleases.isError ? (
            <Alert
              actionLinks={
                <Button
                  onClick={() => void gatewayReleases.refetch()}
                  variant="link"
                >
                  <FormattedMessage {...messages.tryAgain} />
                </Button>
              }
              isInline
              title={intl.formatMessage(messages.gatewayReleaseLoadError)}
              variant="danger"
            />
          ) : null}
          {gatewayReleases.isSuccess && gatewayReleases.data.length === 0 ? (
            <Alert
              isInline
              title={intl.formatMessage(messages.noGatewayReleases)}
              variant="warning"
            />
          ) : null}
          <GatewayTextField
            control={control}
            fieldId="gateway-name"
            isDisabled={createGateway.isPending}
            label={intl.formatMessage(messages.gatewayName)}
            name="name"
          />
          <GatewayTextField
            control={control}
            fieldId="gateway-namespace"
            isDisabled={createGateway.isPending}
            label={intl.formatMessage(messages.namespace)}
            name="namespace"
          />
          <GatewayReleaseSelect
            control={control}
            isDisabled={
              createGateway.isPending ||
              gatewayReleases.isPending ||
              gatewayReleases.isError
            }
            releases={gatewayReleases.data ?? []}
          />
          <ActionGroup>
            <Button
              isDisabled={
                createGateway.isPending ||
                !gatewayReleases.isSuccess ||
                gatewayReleases.data.length === 0
              }
              type="submit"
              variant="primary"
              {...(createGateway.isPending
                ? {
                    isLoading: true,
                    spinnerAriaValueText: intl.formatMessage(
                      messages.provisioningGateway,
                    ),
                  }
                : {})}
            >
              <FormattedMessage {...messages.provisionGateway} />
            </Button>
            <Button
              isDisabled={createGateway.isPending}
              onClick={() => {
                void navigation.navigate(navigation.collectionHref);
              }}
              type="button"
              variant="link"
            >
              <FormattedMessage {...messages.cancel} />
            </Button>
          </ActionGroup>
        </Form>
      </PageSection>
    </>
  );
}
